# ==============================================================================
# devcontainer 差分検知 ＆ 自動停止（省メモリ）リビルドスクリプト
# ==============================================================================
param (
    [switch]$Force # -Force を付けて実行すると差分に関係なく全件強制リビルド
)

# 1. devcontainer CLI のインストール確認
Write-Host "🔍 devcontainer CLI のインストール状態を確認しています..." -ForegroundColor Cyan

if (-not (Get-Command devcontainer -ErrorAction SilentlyContinue)) {
    Write-Host "📦 devcontainer CLI が見つかりませんでした。npm からインストールを開始します！🚀" -ForegroundColor Yellow
    
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Host "❌ npm コマンドが見つかりません。Node.js がインストールされているか確認してください💦" -ForegroundColor Red
        exit 1
    }

    npm install -g @devcontainers/cli
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ @devcontainers/cli のインストールに失敗しました😭" -ForegroundColor Red
        exit 1
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-Host "✨ devcontainer CLI のインストールが完了しました！" -ForegroundColor Green
} else {
    Write-Host "✅ devcontainer CLI の準備完了です👍" -ForegroundColor Green
}

# 2. 探索先フォルダとハッシュキャッシュ、共通Featureの準備
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$sourceFeatureDir = Join-Path $scriptDir "src\my-gemini-tools"
if (-not (Test-Path $sourceFeatureDir)) {
    $sourceFeatureDir = Join-Path $scriptDir "my-gemini-tools"
}

if (Test-Path $sourceFeatureDir) {
    Write-Host "📦 共通 Feature を検出しました: $sourceFeatureDir" -ForegroundColor Green
} else {
    Write-Host "⚠️ 共通 Feature (my-gemini-tools) が見つかりませんでした: $sourceFeatureDir" -ForegroundColor Yellow
}

$searchRoot = "C:\OneDrive"
if (-not (Test-Path $searchRoot) -and $env:OneDrive) {
    $searchRoot = $env:OneDrive
}

$cacheFile = Join-Path $env:LOCALAPPDATA "devcontainer_build_cache.json"

if (-not (Test-Path $searchRoot)) {
    Write-Host "❌ 探索先フォルダ ($searchRoot) が見つかりませんでした💦" -ForegroundColor Red
    exit 1
}

# 過去のハッシュキャッシュを読み込み
$buildCache = @{}
if (Test-Path $cacheFile) {
    try {
        $jsonContent = Get-Content -Path $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($jsonContent) {
            $jsonContent.PSObject.Properties | ForEach-Object { $buildCache[$_.Name] = $_.Value }
        }
    } catch {
        $buildCache = @{}
    }
}

Write-Host ""
Write-Host "📂 $searchRoot 配下から .devcontainer フォルダを探しています...🔍" -ForegroundColor Cyan

# 3. .devcontainer フォルダの探索（-Depth 4 で探索を高速化し、node_modules 等の深追いを防止）
$targets = Get-ChildItem -Path $searchRoot -Directory -Recurse -Depth 4 -Filter ".devcontainer" -Force -ErrorAction SilentlyContinue | 
           ForEach-Object { $_.Parent.FullName } | 
           Select-Object -Unique

if (-not $targets -or $targets.Count -eq 0) {
    Write-Host "🎈 対象となる devcontainer プロジェクトは見つかりませんでした！" -ForegroundColor Yellow
    exit 0
}

Write-Host "🎉 合計 $($targets.Count) 件のプロジェクトを発見しました！差分をチェックします👀✨" -ForegroundColor Green

# 4. 各プロジェクトのハッシュ計算とリビルド＆自動停止
$successCount = 0
$failCount = 0
$skippedCount = 0

foreach ($project in $targets) {
    $devcontainerDir = Join-Path $project ".devcontainer"

    # 共通 Feature (my-gemini-tools) のジャンクション作成・同期
    if ($sourceFeatureDir -and (Test-Path $sourceFeatureDir)) {
        $targetJunction = Join-Path $devcontainerDir "my-gemini-tools"
        $normalizedSource = [System.IO.Path]::GetFullPath($sourceFeatureDir).TrimEnd('\', '/')
        $normalizedTarget = [System.IO.Path]::GetFullPath($targetJunction).TrimEnd('\', '/')

        # 自己ループを回避
        if ($normalizedSource -ne $normalizedTarget) {
            $onWindows = ($env:OS -eq "Windows_NT") -or ($IsWindows -eq $true)
            $linkType = if ($onWindows) { "Junction" } else { "SymbolicLink" }

            $existingItem = Get-Item -LiteralPath $targetJunction -Force -ErrorAction SilentlyContinue
            $needCreate = $true

            if ($existingItem) {
                # 既にジャンクション / リンクが存在する場合、ターゲットを照合
                $currentTarget = if ($existingItem.Target) { $existingItem.Target } else { $existingItem.LinkTarget }
                if ($currentTarget) {
                    $normalizedCurrent = [System.IO.Path]::GetFullPath($currentTarget).TrimEnd('\', '/')
                    if ($normalizedCurrent -eq $normalizedSource) {
                        $needCreate = $false
                    } else {
                        # リンク先が異なる場合は削除して再作成
                        Remove-Item -LiteralPath $targetJunction -Force -Recurse -ErrorAction SilentlyContinue
                    }
                } else {
                    Write-Host "⚠️ $targetJunction に通常フォルダが既に存在するため、ジャンクション作成をスキップします" -ForegroundColor Yellow
                    $needCreate = $false
                }
            }

            if ($needCreate) {
                try {
                    New-Item -ItemType $linkType -Path $targetJunction -Target $sourceFeatureDir -Force -ErrorAction Stop | Out-Null
                    Write-Host "🔗 共通 Feature のジャンクションを作成しました: $targetJunction" -ForegroundColor Cyan
                } catch {
                    Write-Host "⚠️ ジャンクション作成に失敗しました ($targetJunction): $_" -ForegroundColor Yellow
                }
            }
        }
    }

    # .devcontainer 配下の全ファイルのハッシュを結合して指紋を生成
    $fileHashes = Get-ChildItem -Path $devcontainerDir -File -Recurse -ErrorAction SilentlyContinue | 
                  Sort-Object FullName | 
                  ForEach-Object { "$($_.Name):$((Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash)" }
    
    $currentHash = ""
    if ($fileHashes) {
        $combined = $fileHashes -join ";"
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
        $currentHash = [System.BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace("-", "")
    }

    # 差分判定
    $needsRebuild = $Force -or (-not $buildCache.ContainsKey($project)) -or ($buildCache[$project] -ne $currentHash)

    if (-not $needsRebuild) {
        Write-Host "⏭️ スキップ（変更なし）: $project" -ForegroundColor DarkGray
        $skippedCount++
        continue
    }

    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Magenta
    Write-Host "🚀 変更を検知！リビルド＆再生成中: $project" -ForegroundColor Magenta
    Write-Host "========================================================" -ForegroundColor Magenta

    # 古いコンテナを破棄して新しい設定で起動
    devcontainer up --workspace-folder "$project" --remove-existing-container

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ リビルド成功: $project" -ForegroundColor Green
        
        Write-Host "💤 メモリ節約のため、起動したコンテナを安全に停止しています..." -ForegroundColor Yellow
        
        # 表記ゆれ（大文字小文字、スラッシュ／バックスラッシュ）に対応して検索
        $projectSlash = $project.Replace('\', '/')
        $containerIds = docker ps -q --filter "label=devcontainer.local_folder=$project"
        if (-not $containerIds) {
            $containerIds = docker ps -q --filter "label=devcontainer.local_folder=$projectSlash"
        }
        if (-not $containerIds) {
            $containerIds = docker ps -q --filter "label=devcontainer.local_folder=$($project.ToLower())"
        }

        if ($containerIds) {
            docker stop $containerIds | Out-Null
            Write-Host "🛌 コンテナを停止しました！メモリ解放完了です✨" -ForegroundColor Gray
        } else {
            Write-Host "ℹ️ 停止対象のコンテナが見当たりませんでした（すでに停止している可能性があります）" -ForegroundColor DarkGray
        }

        $buildCache[$project] = $currentHash
        $successCount++
    } else {
        Write-Host "⚠️ エラーが発生しました: $project" -ForegroundColor Red
        $failCount++
    }
}

# 5. 最新キャッシュを保存
if ($buildCache.Count -gt 0) {
    $buildCache | ConvertTo-Json -Depth 5 | Set-Content -Path $cacheFile -Encoding UTF8
} else {
    "{}" | Set-Content -Path $cacheFile -Encoding UTF8
}

# 6. 完了レポート
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "🎊 全ての処理が完了しました！PCもメモリもスッキリ軽快です〜！☕🍰" -ForegroundColor Cyan
Write-Host "  ・リビルド＆停止成功: $successCount 件" -ForegroundColor Green
Write-Host "  ・スキップ（差分なし）: $skippedCount 件" -ForegroundColor Gray
if ($failCount -gt 0) {
    Write-Host "  ・失敗: $failCount 件" -ForegroundColor Red
}
Write-Host "========================================================" -ForegroundColor Cyan