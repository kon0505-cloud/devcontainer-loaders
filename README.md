# devcontainer-loaders

ホストマシン上の共通資産（`/opt/`）をコンテナ内へマウントし、ライフサイクルフックと連動させるための **Dev Container Features（ローダー群）** を管理・配信するリポジトリです。  
GitHub Container Registry (GHCR) を通じて各プロジェクトへ自動公開・配信されます。

---

## 💡 解決する課題

1. **設定の重複とメンテナンスの破綻（DRY原則の適用）**
   - 複数プロジェクトの `devcontainer.json` に共通のバインドマウントや拡張機能、初期化スクリプト呼び出しをコピー＆ペーストしていると、設定変更時のメンテナンスが破綻します。
   - Feature としてカプセル化することで、各プロジェクトの `devcontainer.json` に URL を 1 行指定するだけで導入可能にします。
2. **スクリプト実体とコンテナ定義の分離（Loader パターン）**
   - ツールや拡張機能の実体はホスト側（`C:\OneDrive\DevContainers\opt\`）で一元管理し、コンテナ内 `/opt/` へバインドマウントします。
   - Feature 側は「マウントとライフサイクルフックの呼び出し（ローダー）」のみを担当するため、ホスト側でスクリプトを改修した際も、コンテナを毎回フルリビルドすることなく即座に変更が反映されます。
3. **用途に応じた柔軟なモジュール化**
   - エージェントデータ同期（`gemini-tools`）、執筆支援ツール（`novel-tools`）、RPチャット（`rp-chat-ui` / `rp-chat-agent`）など、プロジェクトの目的に応じて必要な Feature だけを自由に組み合わせて利用できます。
4. **防御的なライフサイクルフック（Crash-Safe Hooks）**
   - マウント元が存在しない環境やファイル欠損時でもコンテナ起動が停止（exit code 1 等）しないよう、フック呼び出しを安全にガードしています。

---

## 📁 フォルダ・ファイル構成

```text
devcontainer-loaders/
├── .github/
│   └── workflows/
│       └── release.yaml              # [CI/CD] GHCR 自動公開ワークフロー
├── docs/
│   └── docker-cli-hints-troubleshooting.md # [備忘録] Docker CLI Hints 非表示化と Feature バージョン管理
├── src/                              # 公開対象の Dev Container Features
│   ├── gemini-tools/
│   │   ├── devcontainer-feature.json
│   │   └── install.sh
│   ├── novel-tools/
│   │   ├── devcontainer-feature.json
│   │   └── install.sh
│   ├── rp-chat-agent/
│   │   ├── devcontainer-feature.json
│   │   └── install.sh
│   └── rp-chat-ui/
│       ├── devcontainer-feature.json
│       └── install.sh
├── .devcontainer/
│   ├── devcontainer.json             # 本リポジトリ自身の Dev Container 設定
│   └── devcontainer-lock.json
├── AGENTS.md                         # AI エージェント向け開発・運用ガイドライン
└── README.md
```

---

## 🏗️ アーキテクチャとマウント構造

各 Feature は、ホスト側の共通ディレクトリ（Windows: `C:\OneDrive\DevContainers\opt\`）をコンテナ内の `/opt/` 配下へバインドマウントし、所定のスクリプトへライフサイクルフックを委譲します。

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
└── rp-chat-ui/                                     └── rp-chat-ui/
    ├── devcontainer-hooks/                             ├── devcontainer-hooks/
    │   ├── post-start.sh                               │   ├── post-start.sh
    └── tools/                                          └── tools/
        └── append_turn.py                                  └── append_turn.py
```

### ライフサイクルフックの委譲（Crash-Safe 呼び出し）

各 Feature の `devcontainer-feature.json` にインライン処理を書き込まず、マウントされた `/opt/<feature>/devcontainer-hooks/` 配下のスクリプトへ委譲します。  
ファイルが存在する場合のみ実行する防御的な呼び出し形式をとっているため、マウント元のファイル欠損時でもコンテナ起動が中断されません。

```jsonc
// 例: gemini-tools のフック設定
"postCreateCommand": "if [ -f /opt/gemini-tools/devcontainer-hooks/post-create.sh ]; then bash /opt/gemini-tools/devcontainer-hooks/post-create.sh; fi",
"postStartCommand": "if [ -f /opt/gemini-tools/devcontainer-hooks/post-start.sh ]; then bash /opt/gemini-tools/devcontainer-hooks/post-start.sh; fi",
"postAttachCommand": "if [ -f /opt/gemini-tools/devcontainer-hooks/post-attach.sh ]; then bash /opt/gemini-tools/devcontainer-hooks/post-attach.sh; fi"
```

---

## 📦 提供している Features 一覧

| Feature ID | マウント先 (`/opt/`) | 主な機能・役割 | 推奨・同梱 VS Code 拡張機能 |
| :--- | :--- | :--- | :--- |
| **`gemini-tools`** | `/opt/gemini-tools` | エージェントデータ（`~/.gemini`）永続化ボリューム、Git 設定同期、各種ライフサイクルフック | `google.google-antigravity`<br>`natqe.reload` |
| **`novel-tools`** | `/opt/novel-tools` | 小説執筆・編集支援スクリプト（Markdown 結合・分割・シフト等）のロードとパス設定 | `3w36zj6.textlint`<br>`ritwickdey.liveserver` |
| **`rp-chat-ui`** | `/opt/rp-chat-ui` | RPチャット用 VS Code 拡張機能のシンボリックリンク設定とツール連携 | — |
| **`rp-chat-agent`** | `/opt/rp-chat-agent` | RPチャット用エージェント定義・設定のシンボリックリンク配置 | — |

---

## 🛠️ 各プロジェクトでの利用方法

利用先プロジェクトの `.devcontainer/devcontainer.json` の `features` フィールドに必要なローダーを指定します。

```jsonc
{
  "name": "my-awesome-project",
  "image": "mcr.microsoft.com/devcontainers/javascript-node:24-bookworm",
  "features": {
    // 汎用言語・ランタイム Feature
    "ghcr.io/devcontainers/features/powershell:2": {},

    // 本リポジトリのローダー Features（必要なものを指定）
    "ghcr.io/kon0505-cloud/devcontainer-loaders/gemini-tools:1": {},
    "ghcr.io/kon0505-cloud/devcontainer-loaders/novel-tools:1": {},
    "ghcr.io/kon0505-cloud/devcontainer-loaders/rp-chat-ui:1": {}
  },
  // プロジェクト固有のフックや設定も競合なく併記可能
  "postCreateCommand": "npm install"
}
```

> [!TIP]
> - バージョン指定には `:1`（メジャー固定）または `:latest` が使用可能です。
> - Feature 側のライフサイクルフックとプロジェクト側のライフサイクルフックは Dev Container 仕様により自動的に順次実行されるため、競合の心配はありません。

---

## 🔄 CI/CD と GHCR 自動公開

本リポジトリの `main` / `master` ブランチにコミットが push されると、GitHub Actions（[`.github/workflows/release.yaml`](.github/workflows/release.yaml)）が自動実行されます。  
公式の `devcontainers/action` を使用して `src/` 配下の各 Feature がビルドされ、GitHub Container Registry (GHCR) へ自動公開されます。

### バージョン管理（SemVer）の重要ルール
- `src/<feature>/devcontainer-feature.json` や `install.sh` を変更した際は、**必ず `devcontainer-feature.json` の `version` をインクリメント** してください。
- GHCR（OCI レジストリ）は不変（Immutable）であるため、既に公開済みのバージョンと同一のままだと **GitHub Actions 側で公開処理が自動スキップ** されます。

---

## 📝 開発・変更ルール

1. **Feature 定義と実体ロジックの分離**:
   - `src/<ツール名>/devcontainer-feature.json` にシェル処理を直接インラインで書き込まず、`/opt/<ツール名>/devcontainer-hooks/` 内のスクリプトへ委譲する構成を維持してください。
2. **防御的なフック呼び出し（Crash-safe）**:
   - マウント元が存在しない環境やファイル欠損時でもコンテナ起動が停止（exit code 1 等）しないよう、呼び出しは必ず `if [ -f /opt/... ]; then bash /opt/...; fi` 形式を維持してください。
3. **改行コードと実行権限**:
   - シェルスクリプトはホスト（Windows）とコンテナ（Linux）をまたぐため、改行コードは常に **LF**、実行権限は `chmod +x` を付与してください（CRLF になると `\r: command not found` エラーが発生します）。

---

## 📚 ドキュメント・リファレンス

- [AI エージェント向け開発ガイドライン](AGENTS.md)
- [Docker CLI Hints 非表示化と Dev Container Feature バージョン管理の備忘録](docs/docker-cli-hints-troubleshooting.md)
