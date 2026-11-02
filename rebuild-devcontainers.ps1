# ==============================================================================
# devcontainer 差分検知 ＆ 自動停止（省メモリ）リビルドスクリプト
# ==============================================================================
param (
    [switch]$Force,        # -Force を付けて実行すると差分に関係なく全件強制リビルド
    [Alias("CopyLocal", "SyncLocal", "Junction")]
    [switch]$LocalFeature, # -LocalFeature (または -CopyLocal) を付けるとローカルの my-gemini-tools を各プロジェクトへ実体コピー
    [switch]$Prune         # -Prune を付けると差分の有無に関わらず最後にゴミイメージを一括掃除
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

if ($LocalFeature) {
    if (Test-Path $sourceFeatureDir) {
        Write-Host "📦 [-LocalFeature] 共通 Feature を検出しました: $sourceFeatureDir" -ForegroundColor Green
    } else {
        Write-Host "⚠️ [-LocalFeature] 共通 Feature (my-gemini-tools) が見つかりませんでした: $sourceFeatureDir" -ForegroundColor Yellow
    }
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
           ForEach-Object { 
               $p = $_.Parent.FullName
               # VS Code / Docker ラベル仕様に合わせてドライブ文字を小文字に統一
               if ($p -match '^[a-zA-Z]:') {
                   $p = $p.Substring(0, 1).ToLower() + $p.Substring(1)
               }
               $p
           } | 
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
    # ドライブ文字を確実に小文字化（c:\...）
    if ($project -match '^[a-zA-Z]:') {
        $project = $project.Substring(0, 1).ToLower() + $project.Substring(1)
    }

    $devcontainerDir = Join-Path $project ".devcontainer"

    # 共通 Feature (my-gemini-tools) のローカルコピー同期（-LocalFeature 指定時のみ実行）
    if ($LocalFeature -and $sourceFeatureDir -and (Test-Path $sourceFeatureDir)) {
        $targetDir = Join-Path $devcontainerDir "my-gemini-tools"
        $normalizedSource = [System.IO.Path]::GetFullPath($sourceFeatureDir).TrimEnd('\', '/')
        $normalizedTarget = [System.IO.Path]::GetFullPath($targetDir).TrimEnd('\', '/')

        # 自己ループを回避（ソース自身の中にはコピーしない）
        if ($normalizedSource -ne $normalizedTarget) {
            try {
                # 既存のジャンクション/リンクまたは古いフォルダをクリーンアップ
                if (Test-Path -LiteralPath $targetDir) {
                    $existingItem = Get-Item -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue
                    if ($existingItem.LinkType) {
                        # ジャンクションやシンボリックリンクはリンク自体のみ安全に削除
                        [System.IO.Directory]::Delete($existingItem.FullName, $false)
                    } else {
                        Remove-Item -LiteralPath $targetDir -Force -Recurse -ErrorAction SilentlyContinue
                    }
                }

                # 実体ディレクトリを作成して中身をコピー
                New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
                Copy-Item -Path "$sourceFeatureDir\*" -Destination $targetDir -Recurse -Force -ErrorAction Stop
                Write-Host "📋 共通 Feature (my-gemini-tools) を実体コピーしました: $targetDir" -ForegroundColor Cyan
            } catch {
                Write-Host "⚠️ 共通 Feature のコピーに失敗しました ($targetDir): $_" -ForegroundColor Yellow
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

    # 古いコンテナを破棄して新しい設定で起動（リアルタイムにログを表示しつつ出力をキャプチャ）
    $upOutput = @()
    devcontainer up --workspace-folder "$project" --remove-existing-container | Tee-Object -Variable upOutput

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ リビルド成功: $project" -ForegroundColor Green
        
        Write-Host "💤 メモリ節約のため、起動したコンテナを安全に停止しています..." -ForegroundColor Yellow
        
        # 1. devcontainer up の出力結果（JSON）から直接 containerId を抽出
        $containerId = $null
        foreach ($line in $upOutput) {
            $lineStr = "$line"
            if ($lineStr -match '"containerId"\s*:\s*"([^"]+)"') {
                $containerId = $matches[1]
                break
            }
        }

        # 2. フォールバック: Docker 上の全 devcontainer からパスが一致するものを PowerShell 側で柔軟照合
        # （Docker CLI の --filter でのバックスラッシュ文字化けや大文字小文字の差異を完全に回避）
        if (-not $containerId) {
            $running = docker ps --filter "label=devcontainer.local_folder" --format "{{.ID}}|{{.Label `"devcontainer.local_folder`"}}" 2>$null
            $normProj = $project.Replace('/', '\').TrimEnd('\')
            foreach ($entry in $running) {
                $parts = $entry -split '\|', 2
                if ($parts.Count -eq 2) {
                    $cId = $parts[0].Trim()
                    $cPath = $parts[1].Trim().Replace('/', '\').TrimEnd('\')
                    if ($cPath -eq $normProj -or $cPath.ToLower() -eq $normProj.ToLower()) {
                        $containerId = $cId
                        break
                    }
                }
            }
        }

        # 3. フォールバック: devcontainer.config_file で照合
        if (-not $containerId) {
            $running = docker ps --filter "label=devcontainer.config_file" --format "{{.ID}}|{{.Label `"devcontainer.config_file`"}}" 2>$null
            $normDevDir = $devcontainerDir.Replace('/', '\').TrimEnd('\')
            foreach ($entry in $running) {
                $parts = $entry -split '\|', 2
                if ($parts.Count -eq 2) {
                    $cId = $parts[0].Trim()
                    $cPath = $parts[1].Trim().Replace('/', '\').TrimEnd('\')
                    if ($cPath.StartsWith($normDevDir, [System.StringComparison]::OrdinalIgnoreCase) -or 
                        $cPath.StartsWith($normProj, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $containerId = $cId
                        break
                    }
                }
            }
        }

        if ($containerId) {
            docker stop $containerId | Out-Null
            $shortId = if ($containerId.Length -ge 12) { $containerId.Substring(0, 12) } else { $containerId }
            Write-Host "🛌 コンテナ ($shortId) を停止しました！メモリ解放完了です✨" -ForegroundColor Gray
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

# 6. 未使用の古いゴミイメージ（<none>）の自動クリーンアップ
if ($successCount -gt 0 -or $Prune) {
    Write-Host ""
    Write-Host "🧹 リビルドで発生した不要な古いゴミイメージ (<none>) をクリーンアップしています..." -ForegroundColor Yellow
    $pruneOutput = docker image prune -f 2>$null
    $reclaimed = $pruneOutput | Where-Object { $_ -match "Total reclaimed space" }
    if ($reclaimed -and $reclaimed -notmatch ":\s*0B") {
        Write-Host "✨ ゴミイメージを掃除しました！（$reclaimed）" -ForegroundColor Green
    } else {
        Write-Host "✨ 削除対象のゴミイメージはありませんでした（ディスクは清潔です）👍" -ForegroundColor Gray
    }
}

# 7. 完了レポート
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "🎊 全ての処理が完了しました！PCもメモリもスッキリ軽快です〜！☕🍰" -ForegroundColor Cyan
Write-Host "  ・リビルド＆停止成功: $successCount 件" -ForegroundColor Green
Write-Host "  ・スキップ（差分なし）: $skippedCount 件" -ForegroundColor Gray
if ($failCount -gt 0) {
    Write-Host "  ・失敗: $failCount 件" -ForegroundColor Red
}
Write-Host "========================================================" -ForegroundColor Cyan