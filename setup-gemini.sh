#!/usr/bin/env bash
set -e

DATA_DIR="/var/gemini-data"

# スクリプト自身のディレクトリを取得（共通配置 /var/devcontainer-scripts 等を解決）
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")")" && pwd)"

# ワークスペースディレクトリの解決
# 1. 第1引数指定があれば優先
# 2. CONTAINER_WORKSPACE_FOLDER 環境変数があれば使用
# 3. カレントディレクトリが Git リポジトリまたは devcontainer を含む場合はカレント
# 4. Git のトップレベルリポジトリ
# 5. スクリプトの親ディレクトリ（個別プロジェクト配置時の後方互換）
if [ -n "$1" ] && [ -d "$1" ]; then
    WORKSPACE_DIR="$1"
elif [ -n "$CONTAINER_WORKSPACE_FOLDER" ] && [ -d "$CONTAINER_WORKSPACE_FOLDER" ]; then
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
BACKUP_FILE="$WORKSPACE_DIR/.gemini_backup/gemini-data-latest.tar.gz"

# --- ヘルスチェック（自己診断）モード ---
run_health_check() {
    echo "=== [setup-gemini] Environment Health Check ==="
    local all_ok=true

    # 1. ~/.gemini シンボリックリンク
    if [ -L "$HOME/.gemini" ]; then
        echo " [OK] ~/.gemini -> $(readlink -f "$HOME/.gemini")"
    else
        echo " [NG] ~/.gemini is not a symbolic link"
        all_ok=false
    fi

    # 2. ~/.bash_history シンボリックリンク
    if [ -L "$HOME/.bash_history" ]; then
        echo " [OK] ~/.bash_history -> $(readlink -f "$HOME/.bash_history")"
    else
        echo " [NG] ~/.bash_history is not a symbolic link"
        all_ok=false
    fi

    # 3. backup-gemini CLI
    if command -v backup-gemini >/dev/null 2>&1; then
        echo " [OK] 'backup-gemini' CLI is available: $(which backup-gemini)"
    else
        echo " [NG] 'backup-gemini' CLI is not found in PATH"
        all_ok=false
    fi

    # 4. Git safe.directory
    if git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$WORKSPACE_DIR"; then
        echo " [OK] Git safe.directory is registered ($WORKSPACE_DIR)"
    else
        echo " [WARN] Git safe.directory is not explicitly registered"
    fi

    # 5. Git pager
    if [ "$(git -C "$WORKSPACE_DIR" config core.pager 2>/dev/null)" = "cat" ]; then
        echo " [OK] Git core.pager is 'cat' (pager hang protection enabled)"
    else
        echo " [WARN] Git core.pager is not 'cat'"
    fi

    # 6. Git fileMode
    if [ "$(git -C "$WORKSPACE_DIR" config core.fileMode 2>/dev/null)" = "false" ]; then
        echo " [OK] Git core.fileMode is 'false' (file mode diff ignored)"
    else
        echo " [WARN] Git core.fileMode is not 'false'"
    fi

    # 7. Git editor
    if [ "$(git -C "$WORKSPACE_DIR" config core.editor 2>/dev/null)" = "vi" ]; then
        echo " [OK] Git core.editor is 'vi'"
    else
        echo " [WARN] Git core.editor is not 'vi'"
    fi

    # 8. Git post-commit hook
    if [ -x "$WORKSPACE_DIR/.git/hooks/post-commit" ]; then
        echo " [OK] Git post-commit hook is installed and executable"
    else
        echo " [WARN] Git post-commit hook is missing"
    fi

    # 9. node_modules ownership
    if [ -d "$WORKSPACE_DIR/node_modules" ]; then
        echo " [OK] node_modules exists (owner: $(stat -c "%U:%G" "$WORKSPACE_DIR/node_modules"))"
    else
        echo " [INFO] node_modules does not exist yet (run 'npm install' when needed)"
    fi

    # 10. Git user configuration (user.name & user.email)
    CURRENT_GIT_NAME=$(git config --global user.name 2>/dev/null || true)
    CURRENT_GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
    if [ -n "$CURRENT_GIT_NAME" ] && [ -n "$CURRENT_GIT_EMAIL" ]; then
        echo " [OK] Git user configured: $CURRENT_GIT_NAME <$CURRENT_GIT_EMAIL>"
    elif [ -n "$CURRENT_GIT_NAME" ]; then
        echo " [WARN] Git user.name is set ($CURRENT_GIT_NAME), but user.email is missing"
    else
        echo " [WARN] Git user.name and user.email are not set"
    fi

    echo "==============================================="
    if [ "$all_ok" = true ]; then
        echo "All essential configurations are healthy!"
        return 0
    else
        echo "Some configurations need attention."
        return 1
    fi
}

if [ "$1" = "--check" ]; then
    run_health_check
    exit $?
fi

echo "=== [setup-gemini] Starting Dev Container environment setup ==="

# 1. ディレクトリが存在しない場合は作成（Named Volume未マウント時やテスト実行時の安全対策）
if [ ! -d "$DATA_DIR" ]; then
    echo "Creating $DATA_DIR..."
    sudo mkdir -p "$DATA_DIR"
fi

# 2. ボリュームの所有権を実行ユーザーに設定
echo "Setting ownership of $DATA_DIR to $(id -un):$(id -gn) ($(id -u):$(id -g))..."
sudo chown -R "$(id -u):$(id -g)" "$DATA_DIR"

# 2.5. 新規環境かつバックアップが存在する場合は自動リストア
if [ ! -d "$DATA_DIR/antigravity" ] && [ -f "$BACKUP_FILE" ]; then
    echo "Found existing backup at $BACKUP_FILE. Restoring to $DATA_DIR..."
    tar -xzf "$BACKUP_FILE" -C "$DATA_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$DATA_DIR"
    echo " [OK] Restore completed successfully!"
fi

# 2.6. node_modules の所有権を実行ユーザーに設定（ボリュームマウント時の root 所有対策）
if [ -d "$WORKSPACE_DIR/node_modules" ]; then
    if sudo chown -R "$(id -u):$(id -g)" "$WORKSPACE_DIR/node_modules" 2>/dev/null; then
        echo " [OK] Adjusted node_modules ownership to $(id -un):$(id -gn)"
    else
        echo " [WARN] Could not adjust node_modules ownership (continuing)"
    fi
fi

# 3. 既存の ~/.gemini が通常ディレクトリであれば中身を移行
if [ -L "$HOME/.gemini" ]; then
    echo " [OK] ~/.gemini is already a symbolic link. Skipping migration."
elif [ -d "$HOME/.gemini" ]; then
    echo "Migrating existing $HOME/.gemini data to $DATA_DIR..."
    cp -an "$HOME/.gemini/." "$DATA_DIR/" 2>/dev/null || true
    rm -rf "$HOME/.gemini"
fi

# 4. ~/.gemini シンボリックリンクを作成
echo "Creating symbolic link: $HOME/.gemini -> $DATA_DIR"
ln -sfn "$DATA_DIR" "$HOME/.gemini"

# 5. コマンド履歴（Ctrl+R）の永続化設定
HIST_DIR="$DATA_DIR/commandhistory"
mkdir -p "$HIST_DIR"

# Bash 履歴
touch "$HIST_DIR/.bash_history"
if [ ! -L "$HOME/.bash_history" ]; then
    echo "Linking .bash_history to persistent storage..."
    if [ -f "$HOME/.bash_history" ]; then
        cat "$HOME/.bash_history" >> "$HIST_DIR/.bash_history"
        rm -f "$HOME/.bash_history"
    fi
    ln -sfn "$HIST_DIR/.bash_history" "$HOME/.bash_history"
fi

if [ -f "$HOME/.bashrc" ] && ! grep -q "history -a" "$HOME/.bashrc" 2>/dev/null; then
    echo "Configuring bash history auto-append in .bashrc..."
    cat << 'EOF' >> "$HOME/.bashrc"

# DevContainer shell history persistence
export HISTSIZE=10000
export HISTFILESIZE=20000
PROMPT_COMMAND="history -a; ${PROMPT_COMMAND}"
EOF
fi

if [ -f "$HOME/.bashrc" ] && ! grep -q "GIT_EDITOR=vi" "$HOME/.bashrc" 2>/dev/null; then
    echo "Configuring default editor (vi) in .bashrc..."
    cat << 'EOF' >> "$HOME/.bashrc"

# Default editor configuration (for git rebase -i, etc.)
export EDITOR=vi
export GIT_EDITOR=vi
EOF
fi

# Zsh 履歴（Zshが利用可能な場合）
touch "$HIST_DIR/.zsh_history"
if [ ! -L "$HOME/.zsh_history" ]; then
    echo "Linking .zsh_history to persistent storage..."
    if [ -f "$HOME/.zsh_history" ]; then
        cat "$HOME/.zsh_history" >> "$HIST_DIR/.zsh_history"
        rm -f "$HOME/.zsh_history"
    fi
    ln -sfn "$HIST_DIR/.zsh_history" "$HOME/.zsh_history"
fi

if [ -f "$HOME/.zshrc" ] && ! grep -q "INC_APPEND_HISTORY" "$HOME/.zshrc" 2>/dev/null; then
    echo "Configuring zsh history auto-append in .zshrc..."
    cat << 'EOF' >> "$HOME/.zshrc"

# DevContainer shell history persistence
export HISTSIZE=10000
export SAVEHIST=20000
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY
EOF
fi

if [ -f "$HOME/.zshrc" ] && ! grep -q "GIT_EDITOR=vi" "$HOME/.zshrc" 2>/dev/null; then
    echo "Configuring default editor (vi) in .zshrc..."
    cat << 'EOF' >> "$HOME/.zshrc"

# Default editor configuration (for git rebase -i, etc.)
export EDITOR=vi
export GIT_EDITOR=vi
EOF
fi

# 6. backup-gemini コマンドを登録（共通スクリプト側を優先）
if [ -f "$SCRIPT_DIR/backup-gemini.sh" ]; then
    sudo ln -sfn "$SCRIPT_DIR/backup-gemini.sh" /usr/local/bin/backup-gemini
    echo " [OK] Registered 'backup-gemini' CLI in /usr/local/bin"
elif [ -f "$WORKSPACE_DIR/.devcontainer/backup-gemini.sh" ]; then
    sudo ln -sfn "$WORKSPACE_DIR/.devcontainer/backup-gemini.sh" /usr/local/bin/backup-gemini
    echo " [OK] Registered 'backup-gemini' CLI in /usr/local/bin"
fi

# 7. ホスト側の .gitconfig から user.name と user.email を同期
HOST_GITCONFIG="/var/host-gitconfig"
if [ -f "$HOST_GITCONFIG" ]; then
    HOST_GIT_NAME=$(git config --file "$HOST_GITCONFIG" user.name 2>/dev/null || true)
    HOST_GIT_EMAIL=$(git config --file "$HOST_GITCONFIG" user.email 2>/dev/null || true)

    if [ -n "$HOST_GIT_NAME" ]; then
        git config --global user.name "$HOST_GIT_NAME"
        echo " [OK] Synced git user.name from host: $HOST_GIT_NAME"
    fi
    if [ -n "$HOST_GIT_EMAIL" ]; then
        git config --global user.email "$HOST_GIT_EMAIL"
        echo " [OK] Synced git user.email from host: $HOST_GIT_EMAIL"
    fi
fi

# 8. Git の safe.directory 設定（Docker所有権不一致による exit code 128 対策）
if git config --global --add safe.directory "$WORKSPACE_DIR" 2>/dev/null; then
    echo " [OK] Registered git safe.directory"
else
    echo " [WARN] Failed to register git safe.directory (continuing)"
fi

# 9. Gitリポジトリの確認 & なければ初期化
if [ ! -d "$WORKSPACE_DIR/.git" ]; then
    echo "No git repository found in $WORKSPACE_DIR. Initializing a new git repository..."
    if git -C "$WORKSPACE_DIR" init 2>/dev/null; then
        echo " [OK] Initialized new git repository"
    else
        echo " [WARN] Failed to initialize git repository (continuing)"
    fi
fi

# 10. Git pager 設定（ターミナル停止対策）
if git -C "$WORKSPACE_DIR" config core.pager cat 2>/dev/null; then
    echo " [OK] Configured git pager to 'cat'"
else
    echo " [WARN] Failed to configure git pager (continuing)"
fi

# 11. Git fileMode 設定（パーミッション差分検知対策）
if git -C "$WORKSPACE_DIR" config core.fileMode false 2>/dev/null; then
    echo " [OK] Configured git core.fileMode to 'false'"
else
    echo " [WARN] Failed to configure git core.fileMode (continuing)"
fi

# 12. Git editor 設定（git rebase -i や commit 時に vi を使用）
git config --global core.editor vi 2>/dev/null || true
if git -C "$WORKSPACE_DIR" config core.editor vi 2>/dev/null; then
    echo " [OK] Configured git core.editor to 'vi'"
else
    echo " [WARN] Failed to configure git core.editor (continuing)"
fi

# 13. Git post-commit フックの登録（コミット時の自動バックアップ）
HOOK_DIR="$WORKSPACE_DIR/.git/hooks"
POST_COMMIT_HOOK="$HOOK_DIR/post-commit"

if [ -d "$HOOK_DIR" ]; then
    hook_installed=false
    if [ ! -f "$POST_COMMIT_HOOK" ]; then
        cat << 'EOF' > "$POST_COMMIT_HOOK"
#!/usr/bin/env bash
# コミット完了時にバックグラウンドでGeminiとシェル履歴をOneDriveにバックアップ
if command -v backup-gemini >/dev/null 2>&1; then
    backup-gemini > /dev/null 2>&1 &
fi
EOF
        chmod +x "$POST_COMMIT_HOOK" 2>/dev/null || true
        hook_installed=true
    elif ! grep -q "backup-gemini" "$POST_COMMIT_HOOK" 2>/dev/null; then
        cat << 'EOF' >> "$POST_COMMIT_HOOK"

# Automatic Gemini backup on commit
if command -v backup-gemini >/dev/null 2>&1; then
    backup-gemini > /dev/null 2>&1 &
fi
EOF
        chmod +x "$POST_COMMIT_HOOK" 2>/dev/null || true
        hook_installed=true
    else
        hook_installed=true
    fi

    if [ "$hook_installed" = true ]; then
        echo " [OK] Git post-commit hook configured"
    else
        echo " [WARN] Failed to configure git post-commit hook"
    fi
fi

echo "=== [setup-gemini] Setup completed successfully! ==="
