---
trigger: always_on
---

# 必ずやること
- `.agents/workflows/project_context.md` と `Documents/Mermaids/infrastructure.mermaid` を読み込んで全体像を把握する
- `gce/README.md` を確認してGCE側の構成を把握する
- 明確な指示がない限り作業指示書、Task_mds ディレクトリは無視する

## 必要な時にやること
- トラブルシューティング時は `Documents/OperationPostmortem/` を探索して既知の問題と衝突しないか確認する
- `git add .` を徹底し、add 漏れがないようにする

### 進行停止時の自動回復フロー（sleep + 300s 経過で進展なしの場合）
以下の手順で進行停止を検知し、原因究明と再発防止を自動で実施する:

1. **停止検知**: 最後のツール実行から 300 秒（5分）経過しても応答が得られず、タスク進捗がない場合、ユーザーが「進行停止」を宣言する
2. **状態記録**:
   - 実行中だったタスクの内容
   - 最後に実行したコマンドとその結果（成功/失敗/応答喪失）
   - 現在の git 状態（`git status`）・ブランチ・ahead/behind
3. **原因特定**:
   - 前回のコマンドが `&&` 連結を含んでいなかったか（clinerules 第3条違反）
   - コマンドが SSH 経由で IAP トンネル切断に遭遇していないか
   - プロセスが停止（シグナル/タイムアウト）していないか
   - systemd や cron 等のバックグラウンドジョブが停止していた場合は systemd 監視対象に追加する
4. **再発防止ルールの追加**:
   - 特定した原因に基づき、再発防止ルールを以下に追加:
     - プロジェクト全体のルール → `.clinerules` に追記
     - エージェント固有のルール → `.agents/rules/` 配下の該当 md に追記
     - ワークフロー固有のルール → `.agents/workflows/` 配下の該当 md に追記
   - ルールは **具体的かつ検証可能な禁止パターン / 必須手順** として記述
   - 同日付で「2026-XX-XX 追加」のラベルを付与
5. **中断タスクの再開**: 停止前の状態からタスクを再開し、commit + push まで完了させる
6. **報告**: 原因と対策を一文でユーザーに報告

**適用先の判断基準**:
| 原因の種類 | 追加先 |
|------------|--------|
| シェルコマンドの構文・連結ルール | `.clinerules` + `.agents/rules/cli-safety.md` |
| SSH / kubectl / helm の操作手順 | `.agents/workflows/k3s-ssh-operations.md` |
| エージェントの基本動作 | `.agents/rules/Base-prompt.md` |
| k8s リソース命名・ラベル | `.agents/rules/k8s-naming.md` |
| 特定タスクのワークフロー | `.agents/workflows/` の該当 md |

### SSH / k3s 操作
k3s クラスターへの操作が必要な場合は `.agents/workflows/k3s-ssh-operations.md` を参照すること。

**絶対に守ること:**
- `kubectl` / `helm` / `gcloud` はクライアントマシンから直接実行できない — SSH 経由のみ
- k3s は `k3s-worker` の単一ノード構成。`gcloud` も k3s-worker にのみインストール済み
- SSH ホスト名は `~/.ssh/config` で解決済み: `k3s-worker`
- GCE VM へは IAP SSH（gcloud 自体は k3s-worker から実行）。入口 `mc-proxy` は MIG 管理で
  インスタンス名が動的なため、`gcloud compute instances list --filter="name~^mc-proxy-"` で現行名を取得してから接続する

### Pod 再起動ルール（最重要）
`minecraft` namespace の **全 Deployment（survival / bedrock）** に適用:

- **`kubectl rollout restart` は絶対禁止**
- **正しい手順: `replicas=0` で完全停止 → `replicas=1` で起動**
- helm upgrade 時も必ず先に replicas=0 で停止してから実行

詳細コマンドは `.agents/workflows/k3s-ssh-operations.md` の「全サーバー共通」セクションを参照。

### サブエージェント展開ルール

必要に応じてサブエージェントを展開してよい。ただし:

- **model は必ず `haiku` を指定**（`model="haiku"`）
- プロンプトにプロジェクトルールを明記（日本語出力・SSH経由kubectl・pod再起動手順）
- 詳細は `.claude/commands/haiku-subagent.md` を参照
