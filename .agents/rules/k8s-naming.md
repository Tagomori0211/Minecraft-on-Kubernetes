---
trigger: glob
globs: **/*.yaml,**/*.yml,k8s/**/*
description: Kubernetes / k3s マニフェスト作成・編集時のネーミング規約
---

# k8s Naming Convention — sushiski cluster

## Namespace

**理想:** 環境別プレフィックスを付ける: `prod-`, `dev-`, `monitoring-`
- 例: `prod-minecraft`, `dev-minecraft`, `monitoring-prometheus`

**現状の稼働クラスター:**
- ゲームサーバー: `minecraft` namespace（移行せず運用中）
- k3s 内の監視エージェント（vmagent / Vector）: `monitoring-prometheus` namespace
- 監視本体（VictoriaMetrics / Grafana 等）は GCE `mc-monitoring-1` の Docker Compose（k8s 外）

新規リソースを追加する場合は `minecraft` namespace に揃えること（既存クラスターとの整合性優先）。

## リソース名

- 全て kebab-case（アンダースコア禁止）
- `<service>-<role>` の形式を基本とする
- 例: `deploy-bedrock`, `svc-bedrock`, `pvc-bedrock`, `gcs-backup-cronjob`

## Label 必須セット

全リソースに以下を必ず付けること:

```yaml
labels:
  app.kubernetes.io/name: "<service-name>"
  app.kubernetes.io/component: "<role>"   # proxy / backend / monitoring / cronjob
  app.kubernetes.io/managed-by: "kubectl" # or "helm"
  env: "prod"                             # prod / dev / staging
```

## PVC 命名

- `<service>-<用途>-pvc` の形式
- 既存: `pvc-bedrock`, `pvc-survival`（PVC 名は変更できないため既存はそのまま運用）

## ConfigMap / Secret

- `<service>-<内容>-cm` / `<service>-<内容>-secret`
- 例: `bedrock-backup-script-cm`, `bedrock-backup-secret`

## ❌ やってはいけないこと

- `test`, `temp`, `new` などの曖昧な名前
- Namespace なしのデプロイ（`default` namespace への直デプロイ禁止）
- label なしリソースの作成（Vector がログの `job` ラベルに、バックアップ／アナウンス処理が Pod 特定に `app.kubernetes.io/component` を使うため）
- `kubectl rollout restart` による Pod 再起動（旧 Pod と新 Pod が並走し OOMKiller が発動するリスクあり）
  → 代わりに `scale --replicas=0` → `scale --replicas=1` を使うこと
