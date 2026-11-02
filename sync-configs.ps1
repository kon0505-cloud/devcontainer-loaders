# ==============================================================================
# sync-configs.ps1
# OneDrive 配下の devcontainer.json を集約・一括編集・正規化・逆反映（Pull / Push / Format）スクリプト
# ==============================================================================
param (
    [switch]$Pull,          # OneDrive 配下の devcontainer.json を managed-configs/ へ収集
    [switch]$Push,          # managed-configs/ で編集されたファイルを元の場所へ書き戻す（実質的な変更のみ）
    [switch]$Diff,          # 手元の編集内容と元のファイルとの差分を一覧表示（実質的な変更のみ）
    [switch]$Format,        # managed-configs/ 配下の全ファイルを正規化（コメント除去・キー整列・インデント統一）
    [switch]$IncludeFormat, # Push/Diff 時に整形の有無（コメントやインデント）の差異も含めて対象とする
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
if (-not $Pull -and -not $Push -and -not $Diff -and -not $Format) {
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host " 🛠️ devcontainer.json 一括同期・正規化ツール (sync-configs.ps1)" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "使い方:"
    Write-Host "  .\sync-configs.ps1 -Pull        OneDrive から全 devcontainer.json を集約コピー"
    Write-Host "  .\sync-configs.ps1 -Format      全ファイルを正規化（コメント除去・キー整列・インデント統一）"
    Write-Host "  .\sync-configs.ps1 -Pull -Format 集約と同時に全ファイルを自動正規化"
    Write-Host "  .\sync-configs.ps1 -Diff        手元での編集差分をチェック"
    Write-Host "  .\sync-configs.ps1 -Push        手元の変更を元の場所へ一括書き戻し"
    Write-Host "  .\sync-configs.ps1 -Push -Rebuild  書き戻し後にそのまま一括リビルドを実行"
    Write-Host ""
    Write-Host "探索ルート: $SearchRoot"
    Write-Host "保存先:     $managedDir"
    exit 0
}

if ($Pull -and -not (Test-Path $SearchRoot)) {
    Write-Host "❌ 探索先フォルダ ($SearchRoot) が見つかりませんでした💦" -ForegroundColor Red
    exit 1
}

# ハッシュ計算ヘルパー関数
function Get-FileSha256([string]$filePath) {
    if (-not (Test-Path $filePath)) { return "" }
    return (Get-FileHash -Path $filePath -Algorithm SHA256).Hash
}

# JSONC からコメント・末尾カンマを除去する関数
function Remove-JsonComments([string]$jsonContent) {
    $text = [System.Text.RegularExpressions.Regex]::Replace($jsonContent, "/\*[\s\S]*?\*/", "")
    $pattern = '("(?:\\.|[^"\\])*")|//.*$'
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, $pattern, {
        param($m)
        if ($m.Groups[1].Success) { return $m.Groups[1].Value } else { return "" }
    }, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, ',\s*([}\]])', '$1')
    return $text.Trim()
}

# キーの順序を標準仕様に沿って整列する再帰関数
function Format-DevContainerObject($val) {
    if ($null -eq $val) { return $null }
    
    if ($val -is [System.Collections.IList]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $val) {
            $formattedItem = Format-DevContainerObject $item
            $null = $list.Add($formattedItem)
        }
        return ,$list.ToArray()
    }

    if ($val -is [PSCustomObject] -or $val -is [System.Collections.IDictionary]) {
        # 標準的な理想キー順序リスト
        $priorityKeys = @(
            "name",
            "image", "dockerFile", "build",
            "features", "overrideFeatureInstallOrder",
            "customizations",
            "mounts", "workspaceMount", "workspaceFolder",
            "forwardPorts", "portsAttributes", "otherPortsAttributes",
            "appPort", "containerEnv", "remoteEnv", "containerUser", "remoteUser",
            "updateRemoteUserUID",
            "initializeCommand", "onCreateCommand", "updateContentCommand",
            "postCreateCommand", "postStartCommand", "postAttachCommand",
            "waitFor", "userEnvProbe", "hostRequirements", "privileged", "capAdd", "securityOpt",
            "runArgs", "shutdownAction"
        )
        $ordered = [ordered]@{}
        $propNames = if ($val -is [PSCustomObject]) { $val.PSObject.Properties.Name } else { $val.Keys }

        # 優先順位リストに含まれるキーを配置
        foreach ($k in $priorityKeys) {
            if ($propNames -contains $k) {
                if ($val -is [PSCustomObject]) { $sub = $val.$k } else { $sub = $val[$k] }
                $ordered[$k] = Format-DevContainerObject $sub
            }
        }

        # 残りのキーをアルファベット順で末尾に配置
        $remainingKeys = $propNames | Where-Object { $priorityKeys -notcontains $_ } | Sort-Object
        foreach ($k in $remainingKeys) {
            if ($val -is [PSCustomObject]) { $sub = $val.$k } else { $sub = $val[$k] }
            $ordered[$k] = Format-DevContainerObject $sub
        }
        return $ordered
    }

    return $val
}

# 単一ファイルのフォーマット実行関数
function Format-DevContainerFile([string]$filePath) {
    if (-not (Test-Path $filePath)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
        $clean = Remove-JsonComments $raw
        $obj = $clean | ConvertFrom-Json
        $formattedObj = Format-DevContainerObject $obj
        $formattedJson = $formattedObj | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $filePath -Value ($formattedJson + "`n") -Encoding UTF8
        return $true
    } catch {
        Write-Host "⚠️ フォーマット失敗 ($filePath): $_" -ForegroundColor Yellow
        return $false
    }
}

# 正規化された JSON 文字列を取得する関数（セマンティック差分比較用）
function Get-NormalizedJsonString([string]$filePath) {
    if (-not (Test-Path $filePath)) { return "" }
    try {
        $raw = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
        $clean = Remove-JsonComments $raw
        $obj = $clean | ConvertFrom-Json
        $formattedObj = Format-DevContainerObject $obj
        return ($formattedObj | ConvertTo-Json -Depth 10).Trim()
    } catch {
        return ""
    }
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
        
        # -Format が同時に指定されている場合は即時フォーマット
        if ($Format) {
            $null = Format-DevContainerFile $destConfigFile
        }

        $hash = Get-FileSha256 $destConfigFile

        $mapping[$relPath] = @{
            "projectFolder" = $project
            "sourceFile"    = $srcConfigFile
            "managedFile"   = $destConfigFile
            "pulledHash"    = $hash
            "lastPulledAt"  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            "lastPushedAt"  = ""
        }
        $pulledCount++
    }

    $mapping | ConvertTo-Json -Depth 5 | Set-Content -Path $mappingFile -Encoding UTF8

    Write-Host "🎉 $pulledCount 件の devcontainer.json を managed-configs/ 配下にコピーしました！" -ForegroundColor Green
    if ($Format) {
        Write-Host "✨ 集約と同時に全ファイルの正規化（コメント除去・キー整列・インデント統一）を完了しました！" -ForegroundColor Green
    }
    Write-Host "💡 VS Code 上で managed-configs/ 内のファイルを自由に一括検索・置換・編集してください。" -ForegroundColor Yellow
    exit 0
}

# ------------------------------------------------------------------------------
# 2. FORMAT (単体実行: managed-configs/ 内の全ファイルを正規化・整形)
# ------------------------------------------------------------------------------
if ($Format) {
    Write-Host "🧹 managed-configs/ 配下の devcontainer.json を正規化・整形しています...✨" -ForegroundColor Cyan
    $configFiles = Get-ChildItem -Path $managedDir -Filter "devcontainer.json" -Recurse -File -ErrorAction SilentlyContinue
    
    if (-not $configFiles -or $configFiles.Count -eq 0) {
        Write-Host "🎈 フォーマット対象のファイルが見つかりませんでした。" -ForegroundColor Yellow
        exit 0
    }

    $successCount = 0
    foreach ($f in $configFiles) {
        if (Format-DevContainerFile $f.FullName) {
            $successCount++
        }
    }
    Write-Host "✨ $successCount 件のファイルを正規化しました！（コメント除去、キー整列、インデント統一完了）" -ForegroundColor Green
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
        foreach ($p in $json.PSObject.Properties) {
            $itemDict = [ordered]@{}
            if ($p.Value -is [PSCustomObject]) {
                foreach ($subProp in $p.Value.PSObject.Properties) {
                    $itemDict[$subProp.Name] = $subProp.Value
                }
            } else {
                $itemDict = $p.Value
            }
            $mapping[$p.Name] = $itemDict
        }
    }
} catch {
    Write-Host "❌ マッピングファイルの読み込みに失敗しました。" -ForegroundColor Red
    exit 1
}

# 差分のあるファイルを検出
$changedList = @()
$formatOnlyList = @()
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

    # テキストレベルで完全一致していれば差分なし
    if ($managedHash -eq $sourceHash) {
        continue
    }

    # -IncludeFormat が指定されていない場合、整形の有無（コメントやインデント）だけの差異かを判定
    if (-not $IncludeFormat) {
        $managedNormalized = Get-NormalizedJsonString $managedFile
        $sourceNormalized  = Get-NormalizedJsonString $sourceFile

        # 両方が正常に正規化でき、正規化後の内容が完全に一致する場合
        if ($managedNormalized -and $sourceNormalized -and ($managedNormalized -eq $sourceNormalized)) {
            $formatOnlyList += $key
            continue # 整形の有無の違いだけなので「違い無し（スキップ）」！
        }
    }

    # 実質的な設定変更がある（または -IncludeFormat が指定されている）場合
    $changedList += @{
        "Key"         = $key
        "ManagedFile" = $managedFile
        "SourceFile"  = $sourceFile
        "ManagedHash" = $managedHash
    }
}

# ------------------------------------------------------------------------------
# 3. DIFF (差分チェック)
# ------------------------------------------------------------------------------
if ($Diff) {
    Write-Host "🔍 managed-configs/ と元のファイルとの実質的な差分をチェックしています..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------------"
    
    if ($changedList.Count -eq 0) {
        Write-Host "✨ 変更はありません。手元の設定と元のファイルは完全に一致しています！" -ForegroundColor Green
    } else {
        Write-Host "✏️ 実質的な設定変更を検知したファイル ($($changedList.Count) 件):" -ForegroundColor Yellow
        foreach ($c in $changedList) {
            Write-Host "  ・$($c.Key) -> $($c.SourceFile)" -ForegroundColor Magenta
        }
    }

    if ($formatOnlyList.Count -gt 0 -and -not $IncludeFormat) {
        Write-Host ""
        Write-Host "ℹ️ 整形の差異のみ（コメント・インデント・キー整列）で実質変更なし: $($formatOnlyList.Count) 件" -ForegroundColor DarkGray
        Write-Host "   （※設定値は同じため「違い無し」として判定しています。-IncludeFormat で含めることも可能）" -ForegroundColor DarkGray
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
# 4. PUSH (手元の変更を元の場所へ書き戻す)
# ------------------------------------------------------------------------------
if ($Push) {
    if ($changedList.Count -eq 0) {
        Write-Host "✨ 書き戻す変更はありませんでした（実質的な設定内容が変更されたファイルはありません）。" -ForegroundColor Green
        if ($formatOnlyList.Count -gt 0 -and -not $IncludeFormat) {
            Write-Host "ℹ️ 整形の差異のみのファイルが $($formatOnlyList.Count) 件ありますが、実質的な設定変更がないためスキップしました。" -ForegroundColor DarkGray
            Write-Host "   （整形結果も元のファイルへ反映したい場合は -IncludeFormat を付けて実行してください）" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "📝 以下の $($changedList.Count) 件の実質的な変更を元のプロジェクトへ反映します:" -ForegroundColor Yellow
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
        $nowStr = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        foreach ($c in $changedList) {
            Copy-Item -LiteralPath $c.ManagedFile -Destination $c.SourceFile -Force
            if ($mapping.ContainsKey($c.Key)) {
                $targetItem = $mapping[$c.Key]
                if ($targetItem -is [System.Collections.IDictionary]) {
                    $targetItem["pulledHash"] = $c.ManagedHash
                    $targetItem["lastPushedAt"] = $nowStr
                } else {
                    $targetItem | Add-Member -NotePropertyName "pulledHash" -NotePropertyValue $c.ManagedHash -Force
                    $targetItem | Add-Member -NotePropertyName "lastPushedAt" -NotePropertyValue $nowStr -Force
                }
            }
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
