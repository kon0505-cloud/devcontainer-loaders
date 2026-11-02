#!/bin/sh
set -e

echo "=========================================="
echo "Installing Feature: my-gemini-tools"
echo "=========================================="

# マウントポイントのディレクトリを作成（必要に応じて）
mkdir -p /var/gemini-data
mkdir -p /var/devcontainer-scripts

echo "my-gemini-tools installation completed successfully."

