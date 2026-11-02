# ==============================================================================
# sync-configs.ps1
# OneDrive 配下の devcontainer.json を集約・一括編集・逆反映（Pull / Push）スクリプト
# ==============================================================================
param (
    [switch]$Pull,          # OneDrive 配下の devcontainer.json を managed-configs/ へ収集
    [switch]$Push,          # managed-configs/ で編集されたファイルを元の場所へ書き戻す
    [switch]$Diff,          # 手元の編集内容と元のファイルとの差分を一覧表示
    [switch]$Rebuild,       # Push 完了後に続けて rebuild-devcontainers.ps1 を実行
    [string]$SearchRoot = "", # 探索ルートフォルダ（指定なしの場合は C:\OneDrive または $env:OneDrive）
    [switch]$Force          # Push 時の変更一覧確認をスキップして即座に書き戻す
)

# 探索先と保存先パスの解決
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $SearchRoot) {
    $SearchRoot = "C:\OneDrive"
    if (-not (Test-Path $SearchRoot) -and $env:OneDrive) {
        $SearchRoot = $env:OneDrive
    }
}

$managedDir = Join-Path $scriptDir "managed-configs"
$mappingFile = Join-Path $managedDir "_mapping.json"
$normalizedScriptDir = [System.IO.Path]::GetFullPath($scriptDir).TrimEnd('\', '/')

# 引数なしの場合はヘルプを表示
if (-not $Pull -and -not $Push -and -not $Diff) {
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host " 🛠️ devcontainer.json 一括同期ツール (sync-configs.ps1)" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "使い方:"
    Write-Host "  .\sync-configs.ps1 -Pull        OneDrive から全 devcontainer.json を集約コピー"
    Write-Host "  .\sync-configs.ps1 -Diff        手元での編集差分をチェック"
    Write-Host "  .\sync-configs.ps1 -Push        手元の変更を元の場所へ一括書き戻し"
    Write-Host "  .\sync-configs.ps1 -Push -Rebuild  書き戻し後にそのまま一括リビルドを実行"
    Write-Host ""
    Write-Host "探索ルート: $SearchRoot"
    Write-Host "保存先:     $managedDir"
    exit 0
}

if (-not (Test-Path $SearchRoot)) {
    Write-Host "❌ 探索先フォルダ ($SearchRoot) が見つかりませんでした💦" -ForegroundColor Red
    exit 1
}

# ハッシュ計算ヘルパー関数
function Get-FileSha256([string]$filePath) {
    if (-not (Test-Path $filePath)) { return "" }
    return (Get-FileHash -Path $filePath -Algorithm SHA256).Hash
}

# ------------------------------------------------------------------------------
# 1. PULL (OneDrive から手元に集約)
# ------------------------------------------------------------------------------
if ($Pull) {
    Write-Host "📂 $SearchRoot 配下の devcontainer.json を探索しています...🔍" -ForegroundColor Cyan
    
    # .devcontainer フォルダを探索
    $targets = Get-ChildItem -Path $SearchRoot -Directory -Recurse -Depth 4 -Filter ".devcontainer" -Force -ErrorAction SilentlyContinue | 
               ForEach-Object { $_.Parent.FullName } | 
               Select-Object -Unique

    if (-not $targets -or $targets.Count -eq 0) {
        Write-Host "🎈 対象となる devcontainer プロジェクトは見つかりませんでした！" -ForegroundColor Yellow
        exit 0
    }

    if (-not (Test-Path $managedDir)) {
        New-Item -ItemType Directory -Path $managedDir -Force | Out-Null
    }

    $mapping = @{}
    if (Test-Path $mappingFile) {
        try {
            $json = Get-Content -Path $mappingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json) {
                $json.PSObject.Properties | ForEach-Object { $mapping[$_.Name] = $_.Value }
            }
        } catch {
            $mapping = @{}
        }
    }

    $pulledCount = 0
    foreach ($project in $targets) {
        $normalizedProject = [System.IO.Path]::GetFullPath($project).TrimEnd('\', '/')
        # 自分自身（本リポジトリ）は除外
        if ($normalizedProject -eq $normalizedScriptDir) { continue }

        $srcConfigFile = Join-Path $project ".devcontainer\devcontainer.json"
        if (-not (Test-Path $srcConfigFile)) { continue }

        # 相対パスをベースに保存先ディレクトリを決定（階層構造を保持して名前衝突を防止）
        $relPath = [System.IO.Path]::GetRelativePath($SearchRoot, $project)
        $destDir = Join-Path $managedDir $relPath
        $destConfigFile = Join-Path $destDir "devcontainer.json"

        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $srcConfigFile -Destination $destConfigFile -Force
        $hash = Get-FileSha256 $srcConfigFile

        $mapping[$relPath] = @{
            "projectFolder" = $project
            "sourceFile"    = $srcConfigFile
            "managedFile"   = $destConfigFile
            "pulledHash"    = $hash
            "lastPulledAt"  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        $pulledCount++
    }

    $mapping | ConvertTo-Json -Depth 5 | Set-Content -Path $mappingFile -Encoding UTF8

    Write-Host "🎉 $pulledCount 件の devcontainer.json を managed-configs/ 配下にコピーしました！" -ForegroundColor Green
    Write-Host "💡 VS Code 上で managed-configs/ 内のファイルを自由に一括検索・置換・編集してください。" -ForegroundColor Yellow
    exit 0
}

# ------------------------------------------------------------------------------
# マッピング情報の読み込み（DIFF / PUSH 共通）
# ------------------------------------------------------------------------------
if (-not (Test-Path $mappingFile)) {
    Write-Host "❌ マッピングファイル ($mappingFile) が見つかりません。" -ForegroundColor Red
    Write-Host "💡 先に '.\sync-configs.ps1 -Pull' を実行してファイルを集約してください！" -ForegroundColor Yellow
    exit 1
}

$mapping = @{}
try {
    $json = Get-Content -Path $mappingFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($json) {
        $json.PSObject.Properties | ForEach-Object { $mapping[$_.Name] = $_.Value }
    }
} catch {
    Write-Host "❌ マッピングファイルの読み込みに失敗しました。" -ForegroundColor Red
    exit 1
}

# 差分のあるファイルを検出
$changedList = @()
$missingList = @()

foreach ($key in $mapping.Keys) {
    $item = $mapping[$key]
    $managedFile = $item.managedFile
    $sourceFile  = $item.sourceFile

    if (-not (Test-Path $managedFile)) {
        $missingList += $key
        continue
    }

    $managedHash = Get-FileSha256 $managedFile
    $sourceHash  = Get-FileSha256 $sourceFile

    if ($managedHash -ne $sourceHash) {
        $changedList += @{
            "Key"         = $key
            "ManagedFile" = $managedFile
            "SourceFile"  = $sourceFile
            "ManagedHash" = $managedHash
        }
    }
}

# ------------------------------------------------------------------------------
# 2. DIFF (差分チェック)
# ------------------------------------------------------------------------------
if ($Diff) {
    Write-Host "🔍 managed-configs/ と元のファイルとの差分をチェックしています..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------------"
    
    if ($changedList.Count -eq 0) {
        Write-Host "✨ 変更はありません。手元の設定と元のファイルは完全に一致しています！" -ForegroundColor Green
    } else {
        Write-Host "✏️ 変更を検知したファイル ($($changedList.Count) 件):" -ForegroundColor Yellow
        foreach ($c in $changedList) {
            Write-Host "  ・$($c.Key) -> $($c.SourceFile)" -ForegroundColor Magenta
        }
    }

    if ($missingList.Count -gt 0) {
        Write-Host ""
        Write-Host "⚠️ 手元で削除されたファイル ($($missingList.Count) 件):" -ForegroundColor Red
        foreach ($m in $missingList) {
            Write-Host "  ・$m" -ForegroundColor Red
        }
    }
    Write-Host "------------------------------------------------------------------"
    exit 0
}

# ------------------------------------------------------------------------------
# 3. PUSH (手元の変更を元の場所へ書き戻す)
# ------------------------------------------------------------------------------
if ($Push) {
    if ($changedList.Count -eq 0) {
        Write-Host "✨ 書き戻す変更はありませんでした（全てのファイルが同期済みです）。" -ForegroundColor Green
    } else {
        Write-Host "📝 以下の $($changedList.Count) 件の変更を元のプロジェクトへ反映します:" -ForegroundColor Yellow
        foreach ($c in $changedList) {
            Write-Host "  ・$($c.Key)" -ForegroundColor Cyan
        }

        if (-not $Force) {
            Write-Host ""
            $confirm = Read-Host "元のファイルを上書き反映してよろしいですか？ (y/N)"
            if ($confirm -ne 'y' -and $confirm -ne 'Y') {
                Write-Host "🚫 書き戻しをキャンセルしました。" -ForegroundColor DarkGray
                exit 0
            }
        }

        $pushedCount = 0
        foreach ($c in $changedList) {
            # 安全のため上書きコピー
            Copy-Item -LiteralPath $c.ManagedFile -Destination $c.SourceFile -Force
            # マッピングのハッシュを最新化
            $mapping[$c.Key].pulledHash = $c.ManagedHash
            $mapping[$c.Key].lastPushedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $pushedCount++
        }

        $mapping | ConvertTo-Json -Depth 5 | Set-Content -Path $mappingFile -Encoding UTF8
        Write-Host "✅ $pushedCount 件のファイルを元の場所へ書き戻しました！" -ForegroundColor Green
    }

    # -Rebuild が指定されていれば、rebuild-devcontainers.ps1 を呼び出す
    if ($Rebuild) {
        $rebuildScript = Join-Path $scriptDir "rebuild-devcontainers.ps1"
        if (Test-Path $rebuildScript) {
            Write-Host ""
            Write-Host "==================================================================" -ForegroundColor Magenta
            Write-Host "🔄 -Rebuild オプションを検知：続けて一括リビルドを開始します！" -ForegroundColor Magenta
            Write-Host "==================================================================" -ForegroundColor Magenta
            & $rebuildScript
        } else {
            Write-Host "⚠️ rebuild-devcontainers.ps1 が見つかりませんでした: $rebuildScript" -ForegroundColor Yellow
        }
    }
}
