# 備忘録: Docker CLI Hints（What's next...）非表示化と Dev Container Feature バージョン管理

## 1. 発生した事象

VS Code で Dev Container を起動・接続するたびに、統合ターミナル上に毎回以下のメッセージが表示される事象が発生しました。

```text
What's next:
    Try Docker Debug for seamless, persistent debugging tools in any container or image → docker debug <container-id>
    Learn more at https://docs.docker.com/go/debug-cli/
```

Docker CLI の新機能（Docker Debug など）の利用を促すプロンプト（CLI Hints）ですが、コンテナの起動やリビルドのたびに表示されるためターミナルログが煩雑になります。

---

## 2. 失敗したアプローチとその原因

### 試みたこと
Dev Container Feature ([`src/my-gemini-tools/devcontainer-feature.json`](file:///workspaces/devcontainer-scripts/src/my-gemini-tools/devcontainer-feature.json)) 内に環境変数を追加し、バージョン `1.0.1` として GitHub Container Registry (GHCR) に公開・コンテナをリビルドしました。

```json
  "containerEnv": {
    "DOCKER_CLI_HINTS": "false"
  }
```

### 結果
コンテナをリビルドしても、VS Code 起動時にターミナルへヒントが表示され続けました。

### 原因分析（なぜ効かなかったのか）
- **`containerEnv` のスコープは「コンテナ内部（Guest）」**:
  `containerEnv` はコンテナ内で動作するプロセスに対して環境変数を渡す設定です。
- **ヒントを出力していたのは「ホスト側（Host: Windows/macOS）の Docker CLI」**:
  VS Code の Dev Containers 拡張機能は、コンテナ起動時やターミナル接続時にホストマシン側で `docker exec` や `docker run` などの Docker コマンドを実行しています。
  ヒントメッセージを出力していたのは**ホストマシン側の Docker CLI** であったため、コンテナ内部の環境変数を変更しても一切影響がありませんでした。

---

## 3. 正しい対処方法

ヒントを抑止するには、**ホストマシン側（Windows / macOS / Linux）の Docker 設定** で無効化する必要があります。

### 方法 1: Docker Desktop の GUI 設定（推奨・最も手軽）
1. ホスト側で **Docker Desktop** を開く。
2. 右上の **歯車アイコン（Settings）** をクリック。
3. **General** タブを開く。
4. **「Show CLI hints」** のチェックボックスを **オフ** にする。
5. 右下の **「Apply & restart」** をクリックして保存・再起動する。

### 方法 2: ホストマシンの環境変数に設定する
Docker CLI は環境変数 `DOCKER_CLI_HINTS=false` を読み込んでヒントを抑止する仕様になっています。そのため、ホスト側の環境変数に設定します。

**Windows (PowerShell ユーザー環境変数):**
```powershell
[Environment]::SetEnvironmentVariable("DOCKER_CLI_HINTS", "false", "User")
```
※ 設定後、VS Code やターミナルを再起動すると反映されます。

**Linux / macOS (`~/.bashrc` または `~/.zshrc`):**
```bash
export DOCKER_CLI_HINTS=false
```

### 方法 3: Docker 設定ファイル (`config.json`) に記述する
ホスト側の Docker 設定ファイル（Windows: `%USERPROFILE%\.docker\config.json`、Linux/macOS: `~/.docker/config.json`）に設定を追加します。

```json
{
  "cliHints": false
}
```

---

## 4. Dev Container Feature のバージョン管理・運用の学び

### なぜ「1.0.0 に巻き戻す」ことができないのか？
1. **OCI レジストリ（GHCR）の不変性（Immutability）**:
   - [`.github/workflows/release.yaml`](file:///workspaces/devcontainer-scripts/.github/workflows/release.yaml) で使用している公式の `devcontainers/action` は、一度公開されたバージョンタグ（`1.0.0` や `1.0.1`）を不変として扱います。
   - レジストリ上に既に同一バージョンが存在する場合、**自動的に公開をスキップ**します。
   - そのため、リポジトリのコード上でバージョンを `1.0.0` に戻して push しても、GHCR 上の `1.0.0` は古い内容のまま更新されず、`:1` や `:latest` も `1.0.1` を指したまま不整合が起きます。
2. **手元のキャッシュ（Docker / devcontainer-lock.json）**:
   - クライアント環境に既にダウンロードされたバージョンのキャッシュが存在すると、正しく最新差分が取得されない原因となります。

### 正しい運用方針
- 設定の追加だけでなく、**「誤って追加した設定の削除（クリーンアップ）」であっても、バージョンをインクリメント（`1.0.2` へ進める）** して公開するのがセマンティックバージョニング（SemVer）および OCI 配布の鉄則です。
- 不要になった `containerEnv` 設定を削除し、バージョンを `1.0.2` に上げて push することで、GHCR 上の `:1` および `:latest` がクリーンな最新状態に正しく更新されます。
