---
description: minecraft Pod 安全再起動（OOM回避・replicas=0→1 厳守）
---

# minecraft Pod 安全再起動（OOM回避）

`minecraft` namespace のゲームサーバー deployment（`deploy-survival` / `deploy-bedrock`）を再起動する手順。

**⚠️ `kubectl rollout restart` 禁止**。旧pod・新podが一瞬同時稼働する瞬間に合計メモリ要求が物理メモリを超え、OOMキラーで落ちる（survival は 30Gi 割当）。必ず `replicas=0` → `1` を踏むこと。

## 対象 release / deployment / label / values 対応表

| Release | Deployment | label `app=` | values | コンテナ数 |
|---|---|---|---|---|
| survival | deploy-survival | mc-survival | values-survival.yaml | 3（minecraft / mc-monitor / log-shipper） |
| bedrock | deploy-bedrock | mc-bedrock | （Helmなし・`backend-servers.yaml` を kubectl 管理）| 2（bedrock / mc-monitor） |

## 手順（survival）

1. **対象deployment停止**
   ```bash
   ssh k3s-worker "sudo kubectl scale deployment/deploy-survival -n minecraft --replicas=0"
   ```

2. **pod完全終了を待機**
   ```bash
   ssh k3s-worker "sudo kubectl wait --for=delete pod -l app=mc-survival -n minecraft --timeout=180s"
   ```

3. **（values変更ありの場合）chart 同期 → helm upgrade**（helm は sudo なしで実行）
   ```bash
   rsync -avz --delete /home/shinari/MC_k3s/k8s/onprem/helm/ k3s-worker:~/k8s_manifests/helm/
   ```
   ```bash
   ssh k3s-worker "helm upgrade survival ~/k8s_manifests/helm/minecraft-server -f ~/k8s_manifests/helm/values-survival.yaml -n minecraft"
   ```
   helm upgrade で `deployment.spec.replicas=1` が再適用され、新pod が起動する。

4. **（values変更なしの場合）replicas=1 復元**
   ```bash
   ssh k3s-worker "sudo kubectl scale deployment/deploy-survival -n minecraft --replicas=1"
   ```

5. **起動確認**
   ```bash
   ssh k3s-worker "sudo kubectl get pods -n minecraft -l app=mc-survival"
   ```
   ```bash
   ssh k3s-worker "sudo kubectl logs -n minecraft -l app=mc-survival -c minecraft --tail=120"
   ```
   readiness が `3/3` になればOK（minecraft / mc-monitor / log-shipper の全コンテナが Ready）。

## bedrock 専用手順（Helm なし）

bedrock は Helm 管理外のため、step 3（helm upgrade）は不要。
プレイヤーへのアナウンスが必要な場合は `/bedrock-restart` を使うこと。

```bash
# 停止
ssh k3s-worker "sudo kubectl scale deployment/deploy-bedrock -n minecraft --replicas=0"

# 完全終了待機
ssh k3s-worker "sudo kubectl wait --for=delete pod -l app=mc-bedrock -n minecraft --timeout=180s"

# 起動
ssh k3s-worker "sudo kubectl scale deployment/deploy-bedrock -n minecraft --replicas=1"

# 確認（readiness 2/2）
ssh k3s-worker "sudo kubectl get pods -n minecraft -l app=mc-bedrock"
ssh k3s-worker "sudo kubectl logs -n minecraft -l app=mc-bedrock -c bedrock --tail=60"
```

## トラブルシュート
- pod が `ImagePullBackOff` / `Error` の場合は `kubectl describe pod` を確認
- MOD ダウンロード失敗時は `Modrinth` / `CurseForge` API のレート制限疑い、5分待ってから再起動
