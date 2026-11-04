#!/usr/bin/env bash
set -e

SRC_DIR="/var/gemini-data"

# スクリプト自身のディレクトリを取得（共通配置 /opt/gemini-tools 等を解決）
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
REMOTE_TIMESTAMP_FILE="$BACKUP_DIR/.last_backup_timestamp"
LOCAL_TIMESTAMP_FILE="$SRC_DIR/.last_backup_timestamp"
INTERVAL_SECONDS=$((12 * 3600)) # 12時間

usage() {
    echo "Usage: $0 [options]"
    echo "  (no args)  Run backup immediately (safely aborts if remote backup is newer)"
    echo "  --force    Force backup immediately, ignoring timestamp comparisons"
    echo "  --sync     Sync data (restore if remote backup is newer than local data)"
    echo "  --auto     Auto check: sync if remote is newer, or backup if 12h passed"
    echo "  --restore  Restore data unconditionally from $BACKUP_FILE to $SRC_DIR"
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

# 多重起動の防止（flock による排他制御）
LOCK_FILE="/tmp/backup-gemini-$(id -u).lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[backup-gemini] Another backup or sync process is currently running. Skipping."
    exit 0
fi

# --- リストア処理 ---
restore_data() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "[backup-gemini] No backup file found at $BACKUP_FILE"
        return 1
    fi

    # アーカイブの破損・OneDrive同期中チェック
    if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
        echo "[backup-gemini] ERROR: Backup archive $BACKUP_FILE is incomplete, corrupted, or currently syncing. Aborting restore."
        return 1
    fi

    echo "[backup-gemini] Restoring data from $BACKUP_FILE to $SRC_DIR..."
    sudo mkdir -p "$SRC_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$SRC_DIR"
    tar -xzf "$BACKUP_FILE" -C "$SRC_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$SRC_DIR"

    # リストア成功後、ローカルタイムスタンプをリモートと同期
    if [ -f "$REMOTE_TIMESTAMP_FILE" ]; then
        cp -f "$REMOTE_TIMESTAMP_FILE" "$LOCAL_TIMESTAMP_FILE"
    else
        date +%s > "$LOCAL_TIMESTAMP_FILE"
    fi

    echo "[backup-gemini] Restore completed successfully!"
    return 0
}

if [ "$1" = "--restore" ]; then
    restore_data
    exit 0
fi

# --- 同期処理 (--sync) ---
sync_data() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "[backup-gemini] No remote backup file found to sync."
        return 0
    fi

    local remote_ts=0
    local local_ts=0
    if [ -f "$REMOTE_TIMESTAMP_FILE" ]; then
        remote_ts=$(cat "$REMOTE_TIMESTAMP_FILE" 2>/dev/null || echo 0)
    fi
    if [ -f "$LOCAL_TIMESTAMP_FILE" ]; then
        local_ts=$(cat "$LOCAL_TIMESTAMP_FILE" 2>/dev/null || echo 0)
    fi

    # 新規環境（antigravityディレクトリ不在）またはリモートの方が新しい場合にリストア
    if [ ! -d "$SRC_DIR/antigravity" ] || [ "$remote_ts" -gt "$local_ts" ]; then
        echo "[backup-gemini] Remote backup is newer (remote: $remote_ts > local: $local_ts). Syncing (restoring)..."
        restore_data
    else
        echo "[backup-gemini] Local data is already up to date (remote: $remote_ts, local: $local_ts)."
    fi
    return 0
}

if [ "$1" = "--sync" ]; then
    sync_data
    exit 0
fi

# --- 自動バックアップ・自動同期 (--auto) ---
if [ "$1" = "--auto" ]; then
    # 1. まずリモートが新しいかチェック。新しければ自動でリストア同期して終了
    if [ -f "$REMOTE_TIMESTAMP_FILE" ]; then
        remote_ts=$(cat "$REMOTE_TIMESTAMP_FILE" 2>/dev/null || echo 0)
        local_ts=$(cat "$LOCAL_TIMESTAMP_FILE" 2>/dev/null || echo 0)
        if [ "$remote_ts" -gt "$local_ts" ]; then
            echo "[backup-gemini] Remote backup is newer ($remote_ts > $local_ts). Auto-syncing..."
            restore_data
            exit 0
        fi
    fi

    # 2. リモートが新しくない場合、前回バックアップから12時間経過しているか確認
    if [ -f "$LOCAL_TIMESTAMP_FILE" ]; then
        LAST_BACKUP=$(cat "$LOCAL_TIMESTAMP_FILE" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        ELAPSED=$((NOW - LAST_BACKUP))
        if [ "$ELAPSED" -lt "$INTERVAL_SECONDS" ]; then
            # まだ間隔を満たしていないためスキップ
            exit 0
        fi
    fi
elif [ "$1" = "--force" ]; then
    FORCE_BACKUP=true
elif [ -n "$1" ]; then
    usage
fi

# --- バックアップ処理 ---
if [ ! -d "$SRC_DIR" ]; then
    echo "[backup-gemini] Source directory $SRC_DIR does not exist. Skipping."
    exit 0
fi

# 【安全ガード】別PCの最新バックアップを誤って上書きしないかチェック
if [ "$FORCE_BACKUP" != true ] && [ -f "$REMOTE_TIMESTAMP_FILE" ]; then
    remote_ts=$(cat "$REMOTE_TIMESTAMP_FILE" 2>/dev/null || echo 0)
    local_ts=$(cat "$LOCAL_TIMESTAMP_FILE" 2>/dev/null || echo 0)
    if [ "$remote_ts" -gt "$local_ts" ]; then
        echo "[backup-gemini] ERROR: Remote backup is newer than local storage ($remote_ts > $local_ts)!" >&2
        echo "[backup-gemini] Another PC has created a newer backup in OneDrive." >&2
        echo "[backup-gemini] Please run 'backup-gemini --sync' to update your local data first." >&2
        echo "[backup-gemini] (Use 'backup-gemini --force' if you really want to overwrite the remote backup.)" >&2
        exit 1
    fi
fi

mkdir -p "$BACKUP_DIR"

# 過去の中断やクラッシュで残った古い一時ファイル（*.tmp.*）を自動クリーンアップ
rm -f "$BACKUP_DIR"/*.tmp.* 2>/dev/null || true

echo "[backup-gemini] Creating backup archive to $BACKUP_FILE..."

# 一時ファイルに書き出してからアトミック移動（OneDriveの書き込み途中同期を防止）
TMP_BACKUP="${BACKUP_FILE}.tmp.$$"

# 中断・エラー発生時に一時ファイルを確実に掃除する trap を設定
cleanup() {
    if [ -n "$TMP_BACKUP" ] && [ -f "$TMP_BACKUP" ]; then
        rm -f "$TMP_BACKUP" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM HUP

# バイナリ(agyなど)や一時ログ・ソケット・キャッシュは除外して超軽量化
STATUS=0
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
    -C "$SRC_DIR" . || STATUS=$?

# tar の exit code 1 は「ファイル読み込み中に変更があった（warning）」なので許容
if [ $STATUS -ne 0 ] && [ $STATUS -ne 1 ]; then
    echo "[backup-gemini] Backup failed with status $STATUS"
    exit $STATUS
fi

mv "$TMP_BACKUP" "$BACKUP_FILE"
TMP_BACKUP="" # 正常完了したため trap による削除を解除
trap - EXIT INT TERM HUP

# リモート・ローカル両方のタイムスタンプを同一時刻で更新
NOW=$(date +%s)
echo "$NOW" > "$REMOTE_TIMESTAMP_FILE"
echo "$NOW" > "$LOCAL_TIMESTAMP_FILE"

SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "[backup-gemini] Backup completed successfully! (Size: $SIZE, Timestamp: $NOW)"
