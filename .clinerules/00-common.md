# Minecraft Hybrid Cloud Infrastructure — Cline Rules

## ⚠️ 絶対堅守条件（最優先）

1. **全出力は日本語**：会話・説明・コードコメントすべて日本語。英語ソースは翻訳して提示。
2. **JST時刻の明記**：毎回 `TZ='Asia/Tokyo' date` を実行し、回答冒頭に `JST:yyyy/mm/dd hh:mm`（24h表記）で記載。
3. **コマンドは逐次実行（クライアント側）**：ローカルシェルでは `&&` による複数コマンド連結禁止。SSH の引数文字列内部では可読性のために `&&` 可（`.agents/workflows/k3s-ssh-operations.md` 参照）。
   - **commit + push は必ず3段階に分ける**: `git add -A` →（次メッセージ）→ `git commit -m "..."` →（次メッセージ）→ `git push`
   - **禁止パターン**: `git add -A && git commit`, `git commit && git push`, `cmd1; cmd2`, `cmd1 || cmd2`, `cmd1 | cmd2`
   - **execute_command 前セルフチェック義務**: コマンド文字列に `&&`, `;`（セミコロン）, `||`, `|`（パイプ）が含まれていないか確認すること。含まれる場合は SSH 引数内部かを判断し、ローカルシェルなら分割すること。
4. **各作業終了後は commit + push**：リモートを常に最新に保つ。
5. **コミットメッセージは英語で詳細に**（件名と本文の間は必ず空行を 1 行入れる）：
   ```
   feat(scope): Description

   - Detail 1
   - Detail 2
   ```

## プロジェクト全体像の把握

作業開始時に以下を必ず参照すること:
- `.agents/workflows/project_context.md` — アーキテクチャ・接続フロー・既知の問題・運用ルールの全体概要
- `Documents/Mermaids/infrastructure.mermaid` — インフラ構成図
- `gce/README.md` — GCE 側の構成詳細
- 明確な指示がない限り、`Task_mds` ディレクトリは無視する

## トラブルシューティング

- トラブルシューティング時は `Documents/OperationPostmortem/` を探索し、既知の問題と衝突しないか確認すること
- `git add .` を徹底し、add 漏れがないようにする

## コード変更時のルール

- 変更前に必ずファイルを Read で読む。
- 既存のスタイル・命名規則に合わせる。
- 求められた範囲を超えた変更は行わない。
- **コード内コメントは日本語**。ただし技術用語はそのまま。
- 関数・変数名は英語（スネークケース or キャメルケース、プロジェクトに合わせる）。
- 深いネスト回避 → 早期リターン（Guard Clauses）活用。
- 不要なデバッグ用 `print` / `console.log` は残さない。
- 新規ファイルは必要な場合のみ作成。ドキュメントは明示的要求時のみ。

## セキュリティ

- SQLインジェクション・XSS・コマンドインジェクション等の脆弱性を混入しない。
- 認証情報・シークレットをコードにハードコードしない（`.env` を使用）。
- `.env` ファイルは git に含めない。

---

## SSH / k3s 操作（最重要）

k3s クラスターへの操作は `.agents/workflows/k3s-ssh-operations.md` を参照すること。

**絶対に守ること:**
- `kubectl` / `helm` / `gcloud` はクライアントマシンから直接実行できない — SSH 経由のみ
- k3s は `k3s-worker` の単一ノード構成。`gcloud` も k3s-worker にのみインストール済み
- SSH ホスト名は `~/.ssh/config` で解決済み: `k3s-worker`
- `helm` は **sudo なし** で実行する（`sudo helm` は root に KUBECONFIG が無く localhost:8080 へ接続して失敗する）
- GCE VM へは IAP SSH（gcloud 自体は k3s-worker から実行）
  - GCE は単体 VM `mc-gateway` の 1 台のみ（入口 socat・監視スタック・Status Platform を集約）

### 基本パターン

```bash
# 単発コマンド
ssh k3s-worker 'sudo kubectl get pods -n minecraft'
ssh k3s-worker 'sudo kubectl get pods -n monitoring-prometheus'

# 複数コマンド（SSH 内では && 可）
ssh k3s-worker 'sudo kubectl get pods -n minecraft && sudo kubectl get pvc -n minecraft'

# mc-gateway へ IAP SSH（監視スタックの状態確認）
ssh k3s-worker 'gcloud compute ssh mc-gateway --zone=asia-northeast1-b --tunnel-through-iap --command="sudo docker compose -f /opt/mc-gateway/compose.yaml ps"'
```

---

## Pod 再起動ルール（最重要）

`minecraft` namespace の **ゲームサーバー Deployment（deploy-survival / deploy-bedrock）** に適用:

- **`kubectl rollout restart` は絶対禁止**
- **正しい手順: `replicas=0` で完全停止 → `replicas=1` で起動**
- helm upgrade 時も必ず先に replicas=0 で停止してから実行

**理由:** `rollout restart` や rolling update は旧Pod・新Podが瞬間的に並走し、合計メモリ要求が物理メモリを超えて OOMキラー発動。特に survival(30Gi) で顕著。

```bash
# ❌ 禁止
ssh k3s-worker 'sudo kubectl rollout restart deployment/deploy-survival -n minecraft'

# ✅ 正しい手順
ssh k3s-worker 'sudo kubectl scale deployment deploy-survival -n minecraft --replicas=0'
# 旧Podの完全終了を確認してから
ssh k3s-worker 'sudo kubectl scale deployment deploy-survival -n minecraft --replicas=1'
```

---

## k8s Naming Convention

### Namespace
- **理想:** 環境別プレフィックス: `prod-`, `dev-`, `monitoring-`
- **現状:** ゲームサーバーは `minecraft` namespace で運用中。新規リソース追加時も `minecraft` に揃えること

### リソース名
- 全て kebab-case（アンダースコア禁止）
- `<service>-<role>` 形式: `deploy-bedrock`, `svc-bedrock`, `pvc-bedrock`, `gcs-backup-cronjob`

### 必須 Label
全リソースに以下を必ず付けること:
```yaml
labels:
  app.kubernetes.io/name: "<service-name>"
  app.kubernetes.io/component: "<role>"   # proxy / backend / monitoring / cronjob
  app.kubernetes.io/managed-by: "kubectl" # Helm 管理は "Helm"（{{ .Release.Service }}。既存リソースの採用条件）
  env: "prod"
```

### PVC / ConfigMap / Secret 命名
- PVC: `<service>-<用途>-pvc`（既存は `pvc-bedrock`, `pvc-survival`）
- ConfigMap: `<service>-<内容>-cm`（例: `gcs-backup-script-cm`）
- Secret: `<service>-<内容>-secret`（既存の `gcs-backup-credentials` 等は旧命名のまま運用）

### ❌ 禁止事項
- `test`, `temp`, `new` などの曖昧な名前
- `default` namespace への直デプロイ（namespace なしデプロイ禁止）
- label なしリソースの作成（Vector がログの `job` ラベルに、バックアップ／アナウンス処理が Pod 特定に `app.kubernetes.io/component` を使うため）
- BDS Deployment への `rollout restart`（旧Podと新Podが並走するリスク）

---

## 参照ワークフロー

必要に応じて以下のワークフロー手順書を参照すること:
- `.agents/workflows/k3s-ssh-operations.md` — SSH 経由 kubectl/helm/gcloud 操作詳細
- `.agents/workflows/MCBDS_addon_install.md` — Bedrock アドオン導入手順
- `.agents/workflows/MCBDS_restore.md` — Bedrock ワールドリストア手順

## 進行停止時の自動回復（2026-05-27 追加）

sleep+300s 経過しても進展がない場合、以下を自動実施:
1. 原因特定（`&&` 連結違反 / IAP 切断 / シグナル停止）
2. 再発防止ルールを適切な `.agents/` ドキュメントに追加
3. 中断タスクを再開し commit + push まで完了

詳細フローは `.agents/rules/Base-prompt.md` の「進行停止時の自動回復フロー」を参照。

---

## サブエージェント展開ルール

必要に応じてサブエージェントを展開してよい。ただし:
- **model は必ず `haiku` を指定**
- プロンプトにプロジェクトルールを明記（日本語出力・SSH経由kubectl・pod再起動手順）
- 詳細は `.claude/commands/haiku-subagent.md` を参照

## コマンド化自動判定

ユーザーから新たな指示を受け取った際、以下のメタコマンドで自動判定し、繰り返し発生しうるタスクはコマンド化を提案すること:
- **判定基準**: 反復可能性・手順の複雑さ・エラーリスク・外部依存・知識陳腐化（5軸×2点=10点満点。4点以上で提案、7点以上で強く推奨）
- **原則**: ユーザーの許可なくコマンドファイルを作成しない。必ず提案→確認→作成のフローを踏む
- **詳細**: `.claude/commands/command-recommender.md` を参照

---

## 🔒 シェルコマンド安全実行ルール（2026-05-27 追加）

### プロジェクト全体 grep / find の制限

- **`search_files` ツール（Rust regex、`.git` 自動除外）を最優先で使用する**
- シェル `grep -rl` をプロジェクトルートで実行する場合は **必ず `--exclude-dir=.git` を付与**:
  ```bash
  # ✅ 正しい
  grep -rl "pattern" . --include="*.yaml" --exclude-dir=.git

  # ❌ 禁止（.git/objects をスキャンし長時間応答不能になる）
  grep -rl "pattern" . --include="*.yaml"
  ```
- パイプチェーン（`grep ... | grep -v ...`）は前段が完了するまで出力されないため、**長時間かかるグロブ検索では使用禁止**
- 複数条件の grep は `--exclude-dir=.git` + 単一コマンドで完結させる

### 長時間コマンドの事前評価

- `find /` や `grep -r /` など、スキャン範囲が広大なコマンドは実行前に所要時間を見積もる
- 不確実な場合は `search_files` ツールに置き換える
- `apt install` / `pip install` などシステム変更を伴うコマンドは `requires_approval: true`

### ファイル検索の優先順位

1. **`search_files` ツール** — Rust regex、高速、`.git` 自動除外
2. **`list_files` ツール** — ディレクトリ構造確認
3. **シェル `find` / `grep`** — 上記で不十分な場合のみ。`--exclude-dir=.git` 必須

### 参照

- 詳細は `.agents/workflows/cli-safety.md` を参照

---

## 🗂️ `Documents/` ディレクトリの凡例

- `Mermaids/` — アーキテクチャ図（Mermaid ソース。README に同じ図を埋め込み。SVG 等の画像は置かない）
- `OperationPostmortem/` — インシデントポストモーテム（障害記録。当時の記録のため内容は書き換えない）
- `project_mastery.md` — トラフィックフロー・構成の要約
- `DocMd/` / `Task_mds/` — ローカル専用（.gitignore 対象）
- 新規ドキュメント追加時は適切なサブディレクトリに配置すること
