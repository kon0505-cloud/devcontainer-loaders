# Agent Guidelines (devcontainer-loaders)

本書は、本リポジトリ（`devcontainer-loaders`）上で作業する AI エージェントのための運用・設計ガイドラインです。

---

## 1. アーキテクチャ概要と `/opt/` マウントの構造

本リポジトリの `src/` 配下には、GitHub Container Registry (GHCR) に公開される **Dev Container Features** が定義されています。  
各 Feature はホスト側（Windows: `C:\OneDrive\DevContainers\opt\`）の共通資産をコンテナ内の `/opt/` 配下へバインドマウントし、ライフサイクルフック経由で実行します。

```text
Host (Windows)                                      Container (Linux)
C:\OneDrive\DevContainers\opt\                      /opt/
├── gemini-tools/                                   ├── gemini-tools/
│   ├── devcontainer-hooks/                         │   ├── devcontainer-hooks/
│   │   ├── post-create.sh                          │   │   ├── post-create.sh
│   │   ├── post-start.sh                           │   │   ├── post-start.sh
│   │   └── post-attach.sh                          │   │   └── post-attach.sh
│   ├── backup-gemini.sh                            │   ├── backup-gemini.sh
│   └── setup-gemini.sh                             │   └── setup-gemini.sh
├── novel-tools/                                    ├── novel-tools/
│   ├── devcontainer-hooks/                         │   ├── devcontainer-hooks/
│   │   └── post-start.sh                           │   │   └── post-start.sh
│   ├── join_markdown.py                            │   ├── join_markdown.py
│   ├── shift_markdown.py                           │   ├── shift_markdown.py
│   └── split_markdown.py                           │   └── split_markdown.py
├── rp-chat-agent/                                  ├── rp-chat-agent/
│   ├── devcontainer-hooks/                         │   ├── devcontainer-hooks/
│   │   ├── post-start.sh                           │   │   ├── post-start.sh
│   │   └── link-agents.sh                          │   │   └── link-agents.sh
├── rp-chat-ui/                                     ├── rp-chat-ui/
│   ├── devcontainer-hooks/                         │   ├── devcontainer-hooks/
│   │   ├── post-start.sh                           │   │   ├── post-start.sh
│   └── tools/                                      │   └── tools/
│       └── append_turn.py                          │       └── append_turn.py
└── mysearch-jumper/                                └── mysearch-jumper/
    └── devcontainer-hooks/                             └── devcontainer-hooks/
        └── post-start.sh                                   └── post-start.sh
```

---

## 2. 各 Feature と `/opt/` 配下のリソース対応

### ① `src/gemini-tools`
- **マウント先**: `/opt/gemini-tools`
- **呼び出しフック**:
  - `postCreateCommand`: `/opt/gemini-tools/devcontainer-hooks/post-create.sh` (`setup-gemini.sh` を呼び出し)
  - `postStartCommand`: `/opt/gemini-tools/devcontainer-hooks/post-start.sh` (`backup-gemini --sync` を呼び出し)
  - `postAttachCommand`: `/opt/gemini-tools/devcontainer-hooks/post-attach.sh` (`backup-gemini --auto` を呼び出し)
- **登録コマンド**:
  - `backup-gemini` (`/usr/local/bin/backup-gemini` にシンボリックリンク配置)

### ② `src/novel-tools`
- **マウント先**: `/opt/novel-tools`
- **呼び出しフック**:
  - `postStartCommand`: `/opt/novel-tools/devcontainer-hooks/post-start.sh`
- **登録コマンド**:
  - `join_markdown` (`~/.local/bin/join_markdown`)
  - `shift_markdown` (`~/.local/bin/shift_markdown`)
  - `split_markdown` (`~/.local/bin/split_markdown`)

### ③ `src/rp-chat-ui`
- **マウント先**: `/opt/rp-chat-ui`
- **呼び出しフック**:
  - `postStartCommand`: `/opt/rp-chat-ui/devcontainer-hooks/post-start.sh`
- **登録コマンド・拡張機能**:
  - `rp-chat-append` (`~/.local/bin/rp-chat-append`)
  - VS Code 拡張機能リンク (`~/.vscode-server/extensions/yun-komochi.rp-chat-ui-0.1.0` -> `/opt/rp-chat-ui`)
  - エージェントアセットリンク (`/opt/rp-chat-ui/tools/link-agents.sh`)

### ④ `src/rp-chat-agent`
- **マウント先**: `/opt/rp-chat-agent`
- **呼び出しフック**:
  - `postStartCommand`: `/opt/rp-chat-agent/devcontainer-hooks/post-start.sh`

### ⑤ `src/mysearch-jumper`
- **マウント先**: `/opt/mysearch-jumper`
- **呼び出しフック**:
  - `postStartCommand`: `/opt/mysearch-jumper/devcontainer-hooks/post-start.sh`
- **登録コマンド・拡張機能**:
  - VS Code 拡張機能リンク (`~/.vscode-server/extensions/...` -> `/opt/mysearch-jumper`)

---

## 3. エージェント向け開発・変更ルール

1. **Feature 定義と実体ロジックの分離**:
   - `src/<ツール名>/devcontainer-feature.json` にシェル処理を直接インラインで書き込まず、`/opt/<ツール名>/devcontainer-hooks/` 内のスクリプトへ委譲する構成を維持してください。
2. **防御的なフック呼び出し（Crash-safe）**:
   - マウント元が存在しない環境やファイル欠損時でもコンテナ起動が停止（exit code 1 等）しないよう、呼び出しは必ず `if [ -f /opt/... ]; then bash /opt/...; fi` 形式を維持してください。
3. **改行コードと実行権限**:
   - シェルスクリプトはホスト（Windows）とコンテナ（Linux）をまたぐため、改行コードは常に **LF**、実行権限は `chmod +x` を付与してください（CRLF になると `\r: command not found` エラーが発生します）。
4. **SemVer と GHCR リリース規約**:
   - `src/` 配下の Feature 定義（`devcontainer-feature.json` や `install.sh`）を変更した場合は、必ず `devcontainer-feature.json` の `version` をインクリメントしてください。既存タグと同じバージョンのまま push すると GitHub Actions で GHCR 公開が自動スキップされます。

