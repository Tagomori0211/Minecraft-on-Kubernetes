---
description: k3s クラスター操作スキル（SSH経由）
---

# k3s SSH 操作スキル

## ⚠️ 重要制約（必ず守ること）

**Claude Code クライアントマシンでは以下を直接実行できない:**
- `kubectl` — k3s-worker に SSH してから `sudo kubectl` で実行すること
- `helm` — k3s-worker に SSH してから **sudo なし** で実行すること（`sudo helm` は root に KUBECONFIG が無く失敗する）
- `gcloud` — **k3s-worker にのみインストール済み**

**すべての k3s 操作は SSH 経由で行う。**

---

## 接続先ホスト一覧

| ホスト名 | 役割 | Tailscale IP | kubectl | helm | gcloud |
|---------|------|-------------|---------|------|--------|
| `k3s-worker` | 単一ノード k3s（minecraft / monitoring-prometheus ns） | 100.107.122.45 | `sudo kubectl` ✅ | `helm` ✅ | ✅ |

SSH ホスト名は `~/.ssh/config` で解決済み。GCE VM（mc-gateway）へは k3s-worker から IAP SSH する（後述）。

---

## 基本パターン

### 単発コマンド

```bash
ssh k3s-worker 'sudo kubectl get pods -n minecraft'
```

### 複数コマンドの連結（SSH内では && / ; 可）

CLAUDE.md の `&&` 禁止はクライアント側ローカルシェルへの制約。
SSH の引数文字列内部では可読性・実用性のために `&&` を使ってよい。

```bash
ssh k3s-worker 'sudo kubectl get pods -n minecraft && sudo kubectl get pvc -n minecraft'
```

### 変数展開が必要な場合（クライアント側で展開 → ダブルクォート）

```bash
POD="deploy-bedrock-xxxxx"
ssh k3s-worker "sudo kubectl exec -n minecraft $POD -c bedrock -- send-command 'say hello'"
```

### 変数展開を SSH 先で行う場合（シングルクォートで保護）

```bash
ssh k3s-worker 'POD=$(sudo kubectl get pod -n minecraft -l app=mc-bedrock -o jsonpath="{.items[0].metadata.name}") && echo $POD'
```

---

## よく使う操作集

### Pod 一覧確認

```bash
ssh k3s-worker 'sudo kubectl get pods -n minecraft -o wide'
```

```bash
ssh k3s-worker 'sudo kubectl get pods -n monitoring-prometheus'
```

### ログ確認

```bash
ssh k3s-worker 'sudo kubectl logs deploy/deploy-bedrock -c bedrock -n minecraft --tail=30'
```

```bash
ssh k3s-worker 'sudo kubectl logs deploy/deploy-survival -c minecraft -n minecraft --tail=20'
```

### ⚠️ 全サーバー共通: Pod 再起動は必ず replicas 0 → 1（rollout restart 絶対禁止）

`minecraft` namespace のゲームサーバー Deployment（`deploy-survival` / `deploy-bedrock`）に適用。

**理由:** `rollout restart` や rolling update は旧Pod・新Podが瞬間的に並走し、合計メモリ要求が物理メモリを超えて OOMキラー発動。特に survival(30Gi) で顕著。

```bash
# ❌ 禁止
ssh k3s-worker 'sudo kubectl rollout restart deployment/deploy-survival -n minecraft'

# ✅ 正しい手順（survival の例、deploy-bedrock も同様）
ssh k3s-worker 'sudo kubectl scale deployment deploy-survival -n minecraft --replicas=0'
# 旧Podの完全終了を確認してから
ssh k3s-worker 'sudo kubectl scale deployment deploy-survival -n minecraft --replicas=1'
```

helm upgrade を伴う場合（Helm 管理は survival のみ。bedrock は `backend-servers.yaml` を kubectl apply）:
```bash
# 0. ローカルの chart / values を k3s-worker へ同期
rsync -avz --delete /home/shinari/MC_k3s/k8s/onprem/helm/ k3s-worker:~/k8s_manifests/helm/
# 1. 先に停止
ssh k3s-worker 'sudo kubectl scale deployment deploy-survival -n minecraft --replicas=0'
# 2. 旧Pod完全終了を確認
ssh k3s-worker 'sudo kubectl wait --for=delete pod -l app=mc-survival -n minecraft --timeout=180s'
# 3. helm upgrade（template の replicas=1 が再適用されて新Pod起動）
ssh k3s-worker 'helm upgrade survival ~/k8s_manifests/helm/minecraft-server -f ~/k8s_manifests/helm/values-survival.yaml -n minecraft'
```

### BDS への say コマンド送信

```bash
ssh k3s-worker 'POD=$(sudo kubectl get pod -n minecraft -l app=mc-bedrock --no-headers -o custom-columns=":metadata.name") && sudo kubectl exec -n minecraft $POD -c bedrock -- send-command "say メッセージ"'
```

### Helm リリース一覧

```bash
ssh k3s-worker 'helm list -n minecraft'
```

### gcloud（k3s-worker 経由）

```bash
ssh k3s-worker 'gcloud compute instances list'
```

GCE は単体 VM `mc-gateway` の 1 台（入口 socat は systemd、監視スタックは `/opt/mc-gateway` の compose）:

```bash
ssh k3s-worker 'gcloud compute ssh mc-gateway --zone=asia-northeast1-b --tunnel-through-iap --command="systemctl is-active mc-socat-java mc-socat-bedrock mc-discord-notifier && sudo docker compose -f /opt/mc-gateway/compose.yaml ps"'
```

### 監視エージェント確認（vmagent / Vector）

```bash
ssh k3s-worker 'sudo kubectl logs deploy/vmagent -n monitoring-prometheus --tail=20'
```

```bash
ssh k3s-worker 'sudo kubectl logs ds/vector -n monitoring-prometheus --tail=20'
```

---

## PVC / ファイル操作

PVC 内のファイル操作には helper Pod を立てる（MCBDS_restore.md 参照）。
ファイル転送は `kubectl cp` を SSH 経由で実行する。

```bash
# ローカルファイルを k3s-worker に転送してから kubectl cp
scp ./localfile k3s-worker:/tmp/localfile
ssh k3s-worker 'sudo kubectl cp /tmp/localfile minecraft/<pod-name>:/data/localfile'
```

---

## トラブルシューティング

### Pod が起動しない

```bash
ssh k3s-worker 'sudo kubectl describe pod -n minecraft -l app=mc-bedrock'
```

### ノード状態確認

```bash
ssh k3s-worker 'sudo kubectl get nodes -o wide'
```

### k3s サービス状態

```bash
ssh k3s-worker 'sudo systemctl status k3s'
```
