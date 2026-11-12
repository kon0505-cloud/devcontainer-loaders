# Agent Guidelines (devcontainer-loaders)

本書は、本リポジトリ（`devcontainer-loaders`）上で作業する AI エージェントのための運用・設計ガイドラインです。

---

## 1. アーキテクチャ概要と `/opt/` マウントの構造

本リポジトリの `src/` 配下には、GitHub Container Registry (GHCR) に公開される **Dev Container Features** が定義されています。  
各 Feature はホスト側（Windows: `C:\OneDrive\DevContainers\opt\`）の共通資産をコンテナ内の `/opt/` 配下へバインドマウントし、ライフサイクルフック経由で実行します。

```text
Host (Windows)                                      Container (Linux)
C:\OneDrive\DevContainers\opt\                      /opt/
└── gemini-tools/                                   └── gemini-tools/
    ├── devcontainer-hooks/                             ├── devcontainer-hooks/
    │   ├── post-create.sh                              │   ├── post-create.sh
    │   ├── post-start.sh                               │   ├── post-start.sh
    │   └── post-attach.sh                              │   └── post-attach.sh
    ├── hooks/                                          ├── hooks/
    │   ├── antigravity.json                            │   ├── antigravity.json
    │   └── git/post-commit                             │   └── git/post-commit
    ├── rootfs/usr/local/bin/                           ├── rootfs/usr/local/bin/
    │   ├── backup-gemini                               │   ├── backup-gemini
    │   ├── link-features                               │   ├── link-features
    │   └── notify-gemini                               │   └── notify-gemini
    ├── homefs/.vscode-server/extensions/               ├── homefs/.vscode-server/extensions/
    │   ├── antigravity-explorer-sender                 │   ├── antigravity-explorer-sender
    │   └── antigravity-reloader                        │   └── antigravity-reloader
    ├── workspacefs/docs/                               ├── workspacefs/docs/
    │   ├── antigravity-rules-and-architecture.md       │   ├── antigravity-rules-and-architecture.md
    │   ├── ANTIGRAVITY_HOOKS_GUIDE.md                  │   ├── ANTIGRAVITY_HOOKS_GUIDE.md
    │   └── ANTIGRAVITY_TRANSCRIPT_GUIDE.md             │   └── ANTIGRAVITY_TRANSCRIPT_GUIDE.md
    └── setup-gemini.sh                                 └── setup-gemini.sh
```

---

## 2. 各 Feature と `/opt/` 配下のリソース対応

シンボリックリンク配布元の資産は、コンテナ内の配置先と同一のツリー構造（ルート配下は `rootfs/`、ユーザーホーム配下は `homefs/`、ワークスペース直下は `workspacefs/`）で管理・配置します。

### ① `src/gemini-tools`
- **マウント先**: `/opt/gemini-tools`
- **呼び出しフック**:
  - `postCreateCommand`: `/opt/gemini-tools/devcontainer-hooks/post-create.sh` (`setup-gemini.sh` を呼び出し)
  - `postStartCommand`: `/opt/gemini-tools/devcontainer-hooks/post-start.sh` (`backup-gemini --sync` を呼び出し)
  - `postAttachCommand`: `/opt/gemini-tools/devcontainer-hooks/post-attach.sh` (`backup-gemini --auto` を呼び出し)
- **登録コマンド・拡張機能**:
  - `rootfs/usr/local/bin/backup-gemini` (`/usr/local/bin/backup-gemini` にシンボリックリンク配置: エージェントデータ＆ワークスペース実体ファイル（docs, .agents等）同期・バックアップCLI)
  - `rootfs/usr/local/bin/link-features` (`/usr/local/bin/link-features` にシンボリックリンク配置: 全Feature一括リンクCLI)
  - `rootfs/usr/local/bin/notify-gemini` (`/usr/local/bin/notify-gemini` にシンボリックリンク配置)
  - `homefs/.vscode-server/extensions/antigravity-explorer-sender` (`~/.vscode-server/extensions/...` に配置)
  - `homefs/.vscode-server/extensions/antigravity-reloader` (`~/.vscode-server/extensions/...` に配置)

### ② `src/novel-tools`
- **マウント先**: `/opt/novel-tools`
- **呼び出しフック**:
  - `postStartCommand`: `/opt/novel-tools/devcontainer-hooks/post-start.sh`
- **登録コマンド・拡張機能**:
  - `homefs/.local/bin/join_markdown` (`~/.local/bin/join_markdown`)
  - `homefs/.local/bin/shift_markdown` (`~/.local/bin/shift_markdown`)
  - `homefs/.local/bin/split_markdown` (`~/.local/bin/split_markdown`)
  - `homefs/.vscode-server/extensions/mysearch-jumper` (`~/.vscode-server/extensions/mysearch-jumper`)

### ③ `src/rp-chat-ui`
- **マウント先**: `/opt/rp-chat-ui`
- **呼び出しフック**:
  - `postStartCommand`: `/opt/rp-chat-ui/devcontainer-hooks/post-start.sh`（VS Code 拡張機能リンク、Stop フック登録、旧リンク清掃）
- **登録拡張機能**:
  - `homefs/.vscode-server/extensions/yun-komochi.rp-chat-ui` (`~/.vscode-server/extensions/yun-komochi.rp-chat-ui`)
  *(※旧 `rp-chat-append` コマンドは拡張機能本体へ統合され廃止)*

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
2. **rootfs / homefs / workspacefs ツリーマッピング規則**:
   - シンボリックリンク配布用の資産は、配布先と同じツリー構造（コンテナルート `/` 直下への配置は `/opt/<feature>/rootfs/`、ユーザーホーム `$HOME` 直下への配置は `/opt/<feature>/homefs/`、ワークスペースフォルダ `${containerWorkspaceFolder}` 直下への配置は `/opt/<feature>/workspacefs/`）に配置してください。
   - `workspacefs` 配下の資産は、ワークスペース内の既存通常ファイル（実体ファイル）を誤って破壊しないよう安全保護（上書きスキップ）されます。
   - CLI ツールは拡張子（`.py` や `.sh`）を付けず、適切な shebang（`#!/usr/bin/env python3` 等）と実行権限（`chmod +x`）を付与してコマンド名そのもので配置してください。
3. **フックのドロップイン定義規則（Git / Antigravity）**:
   - 各 Feature が提供するライフサイクルフックは、個別スクリプトで直接登録せず、`/opt/<feature>/hooks/` 配下のファイルとして定義してください（`gemini-tools` の `link-features` により自動で一括マージ・設定されます）。
     - Antigravity フック: `/opt/<feature>/hooks/antigravity.json`（部分 JSON 定義）
     - Git フック: `/opt/<feature>/hooks/git/<event>`（例: `post-commit` スクリプト）
4. **防御的なフック呼び出し（Crash-safe）**:
   - マウント元が存在しない環境やファイル欠損時でもコンテナ起動が停止（exit code 1 等）しないよう、呼び出しは必ず `if [ -f /opt/... ]; then bash /opt/...; fi` 形式を維持してください。
5. **改行コードと実行権限**:
   - シェルスクリプトはホスト（Windows）とコンテナ（Linux）をまたぐため、改行コードは常に **LF**、実行権限は `chmod +x` を付与してください（CRLF になると `\r: command not found` エラーが発生します）。
6. **SemVer と GHCR リリース規約**:
   - `src/` 配下の Feature 定義（`devcontainer-feature.json` や `install.sh`）を変更した場合は、必ず `devcontainer-feature.json` の `version` をインクリメントしてください。既存タグと同じバージョンのまま push すると GitHub Actions で GHCR 公開が自動スキップされます。

