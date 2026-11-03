#!/bin/sh
set -e

echo "=========================================="
echo "Installing Feature: rp-chat-ui"
echo "=========================================="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/usr/local/share/rp-chat-ui"
mkdir -p "${INSTALL_DIR}"
cp "${SCRIPT_DIR}/link-agents.sh" "${INSTALL_DIR}/link-agents.sh"
chmod +x "${INSTALL_DIR}/link-agents.sh"

echo "rp-chat-ui installation completed successfully."
