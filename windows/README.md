# Windows エクスプローラー右クリック統合（Dev Container 直通起動）

Windows のエクスプローラーから、任意のプロジェクトフォルダを**直接 Dev Container 内部で開く**ためのレジストリ登録ツール群です。

通常のように「IDE を起動してからコマンドパレットで Reopen in Container を選ぶ」手間がなくなり、右クリックからワンクリックでコンテナの起動・アタッチが完了します。

---

## 📁 収録ファイル一覧

| ファイル名 | 説明 |
| :--- | :--- |
| [`OpenAntigravityDevContainer.reg`](OpenAntigravityDevContainer.reg) | **Antigravity IDE** 用の右クリックメニュー追加 |
| [`RemoveAntigravityDevContainer.reg`](RemoveAntigravityDevContainer.reg) | **Antigravity IDE** 用の右クリックメニュー削除（登録解除） |
| [`OpenVSCodeDevContainer.reg`](OpenVSCodeDevContainer.reg) | **VS Code** 用の右クリックメニュー追加 |
| [`RemoveVSCodeDevContainer.reg`](RemoveVSCodeDevContainer.reg) | **VS Code** 用の右クリックメニュー削除（登録解除） |

---

## 🚀 使い方

### 1. 登録（インストール）
1. 追加したい方の `.reg` ファイル（`OpenAntigravityDevContainer.reg` または `OpenVSCodeDevContainer.reg`）をダブルクリックします。
2. ユーザーアカウント制御（UAC）およびレジストリエディターの警告が出たら「はい」をクリックします。
3. 「キーおよび値がレジストリに正常に追加されました」と表示されれば登録完了です。

### 2. 起動確認
1. `.devcontainer` を含むプロジェクトフォルダを右クリック（またはフォルダ内で右クリック）します。
2. コンテキストメニューに **「Antigravity Dev Container で開く」** または **「VS Code Dev Container で開く」** が表示されます。
3. クリックすると、IDE が直接コンテナ内部を開いた状態で立ち上がります。

### 3. 解除（アンインストール）
- 右クリックメニューから項目を削除したい場合は、対応する `Remove*.reg` ファイルをダブルクリックして結合してください。

---

## 💡 仕組み（技術解説）

本レジストリ設定は、PowerShell のバックグラウンドワンライナーを呼び出して以下を動的に行っています：

1. **完全非表示（ヘッドレス）起動**:
   - `conhost.exe --headless` 経由で PowerShell を実行。
   - Windows 11 の既定ターミナル（Windows Terminal）の不要なウィンドウ割り込みや、コンソールの一瞬のフラッシュを完全に抑止し、タスクバーや画面に余計なターミナルを残さずバックグラウンドで処理を完結させます。
2. **フォルダパスの取得**:
   - エクスプローラーが渡す対象フォルダパス（`%V`）を取得。
3. **Hex エンコードによる URI 生成**:
   - Dev Containers 拡張機能の URI スキーム仕様に合わせて、フォルダパスを UTF-8 バイト列の 16進数（Hex）文字列にエンコード。
   - `vscode-remote://dev-container+<hex>/workspaces/<フォルダ名>` という形式の直接接続用 URI を動的に組み立てます。
4. **IDE 実行パスの自動解決**:
   - レジストリ（`HKCR\antigravity-ide\` または `HKCR\vscode\`）に記録されている既定の起動コマンドから実行ファイル（`.exe`）のパスを抽出。
   - インストール先が標準外（ユーザー環境やバージョン差異）であっても自動追従して起動します。
5. **引数指定起動と即時終了**:
   - `--folder-uri` 引数に生成した URI を渡して IDE を起動後、PowerShell プロセスは即座に終了（`exit`）します。

---

## ⚠️ 前提条件
- ホスト側で Docker Desktop（または Docker デーモン）が起動していること。
- 対象プロジェクトに `.devcontainer/devcontainer.json` 等の有効な設定が存在すること。
