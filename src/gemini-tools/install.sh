#!/bin/sh
set -e

echo "=========================================="
echo "Installing Feature: gemini-tools"
echo "=========================================="

# マウントポイントのディレクトリを作成（必要に応じて）
mkdir -p /var/gemini-data
mkdir -p /opt/gemini-tools

echo "gemini-tools installation completed successfully."

