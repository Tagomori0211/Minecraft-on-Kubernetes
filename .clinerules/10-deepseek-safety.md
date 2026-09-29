# DeepSeek 安全参加ガードレール（厳格モード）

> **適用条件:** Cline / Roo Code 等で **DeepSeek 系モデル**（deepseek-chat / deepseek-reasoner 等）を
> コーディングエージェントとして使用する場合、本ファイルのルールを `00-common.md` に**上書き適用**する。
> 競合する場合は **本ファイル（より厳格な方）を優先**する。
> Claude など他モデル使用時は本ファイルを参考扱いとし、`00-common.md` を主とする。

DeepSeek は Claude に比べ **幻覚（存在しないファイル・コマンド・APIの捏造）・指示逸脱・破壊的操作の誤発火**の
リスクが相対的に高い。そのため「フル参加は許可するが、不可逆操作には人間の承認を必須化する」設計とする。

---

## 0. 大原則（迷ったら止まる）

1. **推測で破壊的操作をしない。** ファイル名・リソース名・コマンド・IP・namespace が不確実なら、
   実行せず `search_files` / `list_files` / `Read` で**事実を確認**するか、ユーザーに質問する。
2. **存在を捏造しない。** 参照するファイル・関数・Secret・Pod 名は、実在を確認してから言及する。
3. **1 ステップ = 1 検証。** 変更は小さく刻み、各ステップ後に `get` / `--dry-run` / `diff` で結果を確認する。
4. **不明点は質問する。** 仕様・対象・影響範囲が曖昧なまま進めない（DeepSeek は曖昧時の暴走リスクが高い）。

---

## 1. 操作の3分類（最重要）

すべての操作を以下に分類し、**承認必須・絶対禁止**を厳守する。

### 🟢 自走可（承認不要 / DeepSeek が単独実行してよい）

- `Read` / `search_files` / `list_files` による読み取り・調査
- アプリ/マニフェスト/ドキュメントの**ファイル編集**（コード・YAML・Markdown）
- ローカルでの **読み取り専用 / dry-run** コマンド:
  - `git status` / `git diff` / `git log`
  - `terraform plan -var-file=secret.tfvars`（**apply は不可**）
  - `kubectl ... --dry-run=client`（SSH 経由 / 適用なし）
  - lint / format（`black` / `ruff` / `prettier` / `eslint` / `yamllint`）
- `git add -A`（コミットはしない。次項参照）
- 作業ブランチの作成（`git switch -c <branch>`）
- PR の**ドラフト**作成（`gh pr create --draft`）

### 🟡 承認必須（実行前にユーザーへ「実行内容＋影響」を提示し、明示承認を得てから）

| 操作 | 補足 |
|------|------|
| `kubectl scale deployment ... --replicas=0` / `--replicas=1`（本番 `minecraft` ns） | **必ず 0→1 手順**。`rollout restart` は禁止（後述） |
| `helm upgrade` / `helm install` | 先に `--replicas=0` 停止が前提 |
| `terraform apply` | 必ず直前に `plan` を提示し、破壊的変更（destroy/replace）を明示 |
| `git commit` → `git push` | **3 段階分割厳守**（add →〔別メッセージ〕commit →〔別メッセージ〕push）。push は承認必須 |
| GCE / IAP 経由の `docker compose up/down/restart` 等の状態変更 | 入口 VM の停止はサーバー接続断に直結 |
| `apt install` / `apt remove` / `pip install` 等のシステム変更 | `requires_approval: true` 必須 |
| `kubectl cp` / `scp` による本番への書き込み | PVC・サーバーデータに影響 |

### 🔴 絶対禁止（ユーザーが明示的に指示しても、まず警告し代替案を提示）

- **`kubectl rollout restart`**（旧 Pod・新 Pod 並走 → OOMキラー発動）。代わりに `replicas=0→1`。
- **`replicas` を 2 以上に設定**（survival/bedrock のメモリ要求が物理メモリ超過 → OOM）。
- **`kubectl delete`**（namespace / pvc / deployment / node 等）— データ・サービス喪失リスク。
  破壊が必要な場合も DeepSeek は実行せず、Claude / 人間に委譲する。
- **`terraform destroy`** / `terraform apply` での意図しない resource replace。
- **`git push --force` / main ブランチへの直接 push / 履歴改変**。
- **Secret・認証情報・auth-key・`.env` の値を、編集・コミット・標準出力・ログ・PR 本文に出力**。
  - `tailscale-auth-key` / `TAILSCALE_AUTH_KEY` / `TAILSCALE_OATH_*` / GCP 認証ファイルは特に厳禁。
  - コードへのシークレットのハードカウント禁止（必ず `.env` / Secret 参照）。
- **`.env` を git に追加・コミット**（`.gitignore` 済みを確認）。
- **ローカルシェルでのコマンド連結** `&&` `;` `||` `|`（`00-common.md` 第3条）。
  - SSH 引数文字列の内部のみ `&&` 可。
- **`.git` をスキャンする広域 `grep -r` / `find`**（`--exclude-dir=.git` / `-path ./.git -prune` 必須）。

---

## 2. 実行前セルフチェック（コマンドを出す直前に必ず）

```
□ 対象ファイル/リソース名は Read / get で実在を確認したか？（捏造でないか）
□ この操作は 🟢自走可 / 🟡承認必須 / 🔴禁止 のどれか？
□ 🟡なら、影響範囲を提示してユーザー承認を得たか？
□ ローカルシェルに &&  ;  ||  | が混入していないか？（SSH 引数内部を除く）
□ kubectl/helm/gcloud をローカル直実行していないか？（必ず ssh 経由）
□ grep/find に --exclude-dir=.git を付けたか？
□ Secret/auth-key を出力に含めていないか？
```

---

## 3. インフラ操作の前提（DeepSeek が誤りやすい点）

- **`kubectl` / `helm` / `gcloud` はローカルから直接実行不可。** 必ず `ssh k3s-worker '...'` 経由。
  詳細は [`.agents/workflows/k3s-ssh-operations.md`](../.agents/workflows/k3s-ssh-operations.md)。
- **GCE は単体 VM `mc-gateway` の 1 台のみ**。`mc-proxy-*` / `mc-monitoring-1` / `tagomori-app` は統合済みで**存在しない**。
  IAP SSH は `gcloud compute ssh mc-gateway --zone=asia-northeast1-b --tunnel-through-iap`（k3s-worker 経由）。
- **Pod ラベルは `app.kubernetes.io/component=survival|bedrock`**（`name=` ではない）。
- **Pod 再起動は全 Deployment で `replicas=0`→（完全停止確認）→`replicas=1`**。`rollout restart` 禁止。
- namespace 無指定デプロイ・`default` への直デプロイ禁止。新規リソースは `minecraft` ns に揃える。

---

## 4. 困ったとき / 進行が止まったとき

- 同じコマンドで 2 回以上失敗したら、**自己流リトライを止めて**原因（連結違反 / SSH 切断 / 対象名誤り）を
  切り分け、ユーザーに状況を報告する。
- 大きなタスクは**作業計画を先に提示**し、承認を得てから着手する（DeepSeek の暴走防止）。
- 既知の問題は [`Documents/OperationPostmortem/`](../Documents/OperationPostmortem/) を確認し、衝突を避ける。

---

## 5. 参照

- [`00-common.md`](./00-common.md) — 全エージェント共通ルール（本ファイルの土台）
- [`.agents/rules/cli-safety.md`](../.agents/rules/cli-safety.md) — シェル安全実行
- [`.agents/rules/k8s-naming.md`](../.agents/rules/k8s-naming.md) — k8s 命名規約
- [`.agents/workflows/k3s-ssh-operations.md`](../.agents/workflows/k3s-ssh-operations.md) — SSH 経由操作
- [`.agents/workflows/project_context.md`](../.agents/workflows/project_context.md) — 全体像
