#!/bin/bash
set -e

SOURCE_DIR="/var/rp-chat-ui/.devcontainer/agents"
TARGET_DIR="${1:-${CONTAINER_WORKSPACE_FOLDER:-$(pwd)}}"

echo "[RP-Chat-UI] Linking agent assets from ${SOURCE_DIR} to ${TARGET_DIR}..."

# マウント元が存在しない場合は安全にスキップ
if [ ! -d "${SOURCE_DIR}" ]; then
  echo "[RP-Chat-UI] Notice: ${SOURCE_DIR} not found. Skipping."
  exit 0
fi

# 全ファイル（隠しファイル含む）を走査して相対パスを維持したままシンボリックリンク
find "${SOURCE_DIR}" -type f | while read -r src_file; do
  rel_path="${src_file#"${SOURCE_DIR}/"}"
  target_file="${TARGET_DIR}/${rel_path}"
  target_parent="$(dirname "${target_file}")"

  # 親ディレクトリを作成してリンクを強制配置
  mkdir -p "${target_parent}"
  ln -sfn "${src_file}" "${target_file}"
  echo "  -> Linked: ${rel_path}"
done

echo "[RP-Chat-UI] Agent assets linked successfully!"
