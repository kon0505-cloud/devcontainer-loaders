#!/usr/bin/env bash
set -e

SRC_DIR="/var/gemini-data"

# スクリプト自身のディレクトリを取得（共通配置 /var/devcontainer-scripts 等を解決）
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")")" && pwd)"

# ワークスペースディレクトリの解決
# 1. CONTAINER_WORKSPACE_FOLDER 環境変数があれば使用
# 2. カレントディレクトリが Git リポジトリまたは devcontainer を含む場合はカレント
# 3. Git のトップレベルリポジトリ
# 4. スクリプトの親ディレクトリ（個別プロジェクト配置時の後方互換）
if [ -n "$CONTAINER_WORKSPACE_FOLDER" ] && [ -d "$CONTAINER_WORKSPACE_FOLDER" ]; then
    WORKSPACE_DIR="$CONTAINER_WORKSPACE_FOLDER"
elif [ -d "$PWD/.git" ] || [ -d "$PWD/.devcontainer" ]; then
    WORKSPACE_DIR="$PWD"
elif git rev-parse --show-toplevel >/dev/null 2>&1; then
    WORKSPACE_DIR="$(git rev-parse --show-toplevel)"
else
    PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [ "$PARENT_DIR" != "/var" ] && [ "$PARENT_DIR" != "/" ]; then
        WORKSPACE_DIR="$PARENT_DIR"
    else
        WORKSPACE_DIR="$PWD"
    fi
fi

BACKUP_DIR="$WORKSPACE_DIR/.gemini_backup"
BACKUP_FILE="$BACKUP_DIR/gemini-data-latest.tar.gz"
TIMESTAMP_FILE="$BACKUP_DIR/.last_backup_timestamp"
INTERVAL_SECONDS=$((12 * 3600)) # 12時間

usage() {
    echo "Usage: $0 [options]"
    echo "  (no args)  Run backup immediately"
    echo "  --auto     Run backup only if ${INTERVAL_SECONDS}s (12h) have passed since last backup"
    echo "  --restore  Restore data from $BACKUP_FILE to $SRC_DIR"
    echo "  --check    Run Dev Container environment health check"
    exit 1
}

# --- ヘルスチェックの呼び出し ---
if [ "$1" = "--check" ]; then
    if [ -f "$SCRIPT_DIR/setup-gemini.sh" ]; then
        exec bash "$SCRIPT_DIR/setup-gemini.sh" --check
    elif [ -f "$WORKSPACE_DIR/.devcontainer/setup-gemini.sh" ]; then
        exec bash "$WORKSPACE_DIR/.devcontainer/setup-gemini.sh" --check
    else
        echo "[backup-gemini] setup-gemini.sh not found for health check."
        exit 1
    fi
fi

# --- リストア処理 ---
restore_data() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "[backup-gemini] No backup file found at $BACKUP_FILE"
        return 1
    fi

    echo "[backup-gemini] Restoring data from $BACKUP_FILE to $SRC_DIR..."
    sudo mkdir -p "$SRC_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$SRC_DIR"
    tar -xzf "$BACKUP_FILE" -C "$SRC_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$SRC_DIR"
    echo "[backup-gemini] Restore completed successfully!"
    return 0
}

if [ "$1" = "--restore" ]; then
    restore_data
    exit 0
fi

# --- 自動バックアップの判定 ---
if [ "$1" = "--auto" ]; then
    if [ -f "$TIMESTAMP_FILE" ]; then
        LAST_BACKUP=$(cat "$TIMESTAMP_FILE" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        ELAPSED=$((NOW - LAST_BACKUP))
        if [ "$ELAPSED" -lt "$INTERVAL_SECONDS" ]; then
            # まだ間隔を満たしていないためスキップ
            exit 0
        fi
    fi
elif [ -n "$1" ]; then
    usage
fi

# --- バックアップ処理 ---
if [ ! -d "$SRC_DIR" ]; then
    echo "[backup-gemini] Source directory $SRC_DIR does not exist. Skipping."
    exit 0
fi

mkdir -p "$BACKUP_DIR"

echo "[backup-gemini] Creating backup archive to $BACKUP_FILE..."

# 一時ファイルに書き出してからアトミック移動（OneDriveの書き込み途中同期を防止）
TMP_BACKUP="${BACKUP_FILE}.tmp.$$"

# バイナリ(agyなど)や一時ログ・ソケット・キャッシュは除外して超軽量化
tar -czf "$TMP_BACKUP" \
    --exclude='bin' \
    --exclude='*/bin' \
    --exclude='*/crashes' \
    --exclude='*/cache' \
    --exclude='*/presence' \
    --exclude='*/daemon' \
    --exclude='logs' \
    --exclude='*/log' \
    --exclude='*.lock' \
    --exclude='*.sock' \
    -C "$SRC_DIR" . || {
        STATUS=$?
        # tar の warning (file changed as we read it) は許容
        if [ $STATUS -ne 1 ]; then
            rm -f "$TMP_BACKUP"
            echo "[backup-gemini] Backup failed with status $STATUS"
            exit $STATUS
        fi
    }

mv "$TMP_BACKUP" "$BACKUP_FILE"
date +%s > "$TIMESTAMP_FILE"

SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "[backup-gemini] Backup completed successfully! (Size: $SIZE)"
