<!-- ⚠️ このファイルは .clinerules の補完です。全絶対ルールは .clinerules を参照してください -->

# 開発環境

## システム
- OS: Ubuntu 22.04.5 LTS (Linux 5.15.0, x86_64)
- Shell: bash

## インストール済みランタイム

| ツール | バージョン |
|--------|-----------|
| Python | 3.10.12 (`/usr/bin/python3`) |
| Node.js | v20.20.0 (nvm 管理) |
| npm | 10.8.2 |
| Docker | 29.2.1 |
| git | 2.34.1 |
| kubectl | クライアントのみ（クラスタ操作は SSH 経由） |
| helm | クライアントのみ |
| gcloud | クライアントのみ |

---

# プロジェクト概要

Minecraft ハイブリッドクラウドインフラの構成管理リポジトリ。
詳細は `.agents/workflows/project_context.md` を参照。
（旧 `session-context.md` は 2026-06-10 に廃止。現況は Claude Code の自動メモリで管理）

## 主要ディレクトリ

| ディレクトリ | 用途 |
|-------------|------|
| `.clinerules` | **メインルールファイル**（絶対ルール・運用ルールすべて） |
| `.agents/` | エージェント細則（rules/）・ワークフロー手順（workflows/） |
| `k8s/onprem/` | k3s クラスタ用 Kubernetes マニフェスト・Helm charts |
| `gce/` | GCE 入口 `mc-proxy`（MIG）の Docker Compose・cloud-init・systemd。`gce/monitoring/` は監視 VM `mc-monitoring-1` 用（Grafana ダッシュボード JSON 含む） |
| `Terraform/` | GCP・Proxmox リソースの IaC 定義 |
| `Ansible/` | k3s + Tailscale のインストール・マニフェスト適用 |
| `Documents/` | アーキテクチャ図・ポストモーテム |
| `.sh/` | 手動運用スクリプト（BDS へのメッセージ送信） |

⚠️ `gce/` 配下のパスは GCE の cloud-init が起動時に main ブランチから clone して参照するため、移動・改名しないこと。

---

# 言語別コーディング規約

（`.clinerules`「コード変更時のルール」に加えて）

## Python
- フォーマッタ: `black`
- linter: `flake8` or `ruff`
- 型ヒントを積極的に使用
- 仮想環境: `venv`（`.venv/` ディレクトリ）

## JavaScript / TypeScript
- パッケージマネージャ: `npm`
- フォーマッタ: `prettier`
- linter: `eslint`
- TypeScript を優先

## Kubernetes マニフェスト
- `.clinerules`「k8s Naming Convention」に従う
- YAML はスペース 2 インデント

---

# よく使うコマンド

主なもの:

```bash
# k3s Pod 状態確認
ssh k3s-worker 'sudo kubectl get pods -n minecraft'

# GCE 入口 VM（MIG・インスタンス名は動的）へ IAP SSH
ssh -t k3s-worker 'NAME=$(gcloud compute instances list --filter="name~^mc-proxy-" --format="value(name)") && gcloud compute ssh "$NAME" --zone=asia-northeast1-b --tunnel-through-iap'

# Terraform
cd Terraform && terraform plan -var-file=secret.tfvars

# Git 作業完了時（.clinerules 第3条参照: 必ず3段階で実行）
git add -A
git commit -m "feat(scope): description..."
git push
```

---

# コマンド化推奨（自動判定ルール）

ユーザーから新たな指示を受け取った際は、それが**繰り返し発生する可能性が高いタスク**か自動判定し、該当する場合は `.claude/commands/<name>.md` へのコマンド化を提案すること。判定基準・テンプレート・提案メッセージ形式は [.claude/commands/command-recommender.md](commands/command-recommender.md) に従う。

- **判定タイミング**: 新しい指示を受け取るたびに内部で評価する（明示的な `/command-recommender` 呼び出しを待たない）
- **原則**: ユーザーの許可なくコマンドファイルを作成しない。必ず「提案 → 確認 → 作成」のフローを踏む
- **スコア基準**（5軸 × 0〜2点）:
  - 0〜3点: コマンド化不要、そのまま実行
  - 4〜6点: コマンド化を提案
  - 7〜10点: コマンド化を強く推奨
- 提案前に必ず `.claude/commands/` の既存コマンドと重複チェックを行う