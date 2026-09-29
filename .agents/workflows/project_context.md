---
description: プロジェクト進捗管理
---

# Minecraft Hybrid Cloud Infrastructure (Minecraft-on-Kubernetes)

## 概要

GCP (GCE) とオンプレミス (k3s) を Tailscale VPN で接続した、Minecraft (Java版 / Bedrock版) のハイブリッドクラウド構成リポジトリ。
アーキテクチャの一次情報はリポジトリ直下の `README.md` と `Documents/Mermaids/*.mermaid`。

## アーキテクチャ構成

### 1. GCE 入口: mc-proxy（`Terraform/gce.tf` / `gce/`）

- **Managed Instance Group** `mc-proxy-mig`（size=1、TCP:25565 ヘルスチェックでオートヒーリング）
  - インスタンス名は動的（`mc-proxy-xxxx`）。`mc-proxy-1` という固定名は存在しない
  - e2-micro / pd-balanced 20GB / asia-northeast1-b / 静的IP `35.200.78.252`
- **Docker Compose（host network, `gce/compose.yaml`）**
  - `socat-tcp`: Java TCP 25565 → `100.107.122.45:30065`（survival NodePort）
  - `socat-bedrock`: Bedrock UDP 19132 → `100.107.122.45:19132`（fork 透過転送）
  - `node-exporter` + `vmagent-host`: ホストメトリクスを mc-monitoring-1 へ remote_write
- **tailscaled**: systemd (kernel mode)。hostname `gce-mc-proxy`（Tailscale IP は MIG 再作成で変わる）
- cloud-init（`gce/cloud-init.yaml`）が起動時に本リポジトリ main の `gce/` を clone して配置する

### 2. GCE 監視: mc-monitoring-1（`Terraform/monitoring.tf` / `gce/monitoring/`）

- e2-small / Tailscale `gce-mc-monitoring`（100.121.113.37）
- Docker Compose: VictoriaMetrics（:8428, 保持14日）/ VictoriaLogs（:9428, 保持30日）/
  Vector aggregator（:9001）/ Grafana（:3000, Tailscale 経由のみ）/ vmalert / Alertmanager /
  alertmanager-discord / discord-notifier（課金アラート Pub/Sub pull）
- cloud-init（`gce/monitoring-cloud-init.yaml`）が起動時に `gce/monitoring/` を clone して配置する

### 3. オンプレ k3s（`k8s/onprem/`）

- Proxmox 上の VM `k3s-worker`（192.168.0.151 / Tailscale 100.107.122.45）による **単一ノード k3s**
- **minecraft namespace（本リポジトリ管理）**
  - `deploy-bedrock`: Bedrock BDS（4-8Gi, hostPort 19132, LEVEL_NAME `sushi_server`）— `backend-servers.yaml`
  - **Java（survival）は休眠中**（2026-09-30〜）: Helm release `survival` は削除済み。ワールドは
    `pvc-survival`（PV は reclaimPolicy: Retain）で保持 — `survival-pvc-dormant.yaml`。
    再開時は `helm upgrade --install survival ... -f values-survival.yaml` で PVC を採用し、
    vmagent の survival ジョブ・GCS バックアップの `JAVA_SERVERS`・Pub/Sub の `SERVER_CONFIG` を戻す
  - `bq-metrics`: VictoriaMetrics → BigQuery（15 秒解像度、Java / Bedrock 共通）— `40-bq-metrics.yaml`
  - `mc-log-shipper` DaemonSet: ログイン/ログアウト → Pub/Sub `mc-raw-logs`
  - `pubsub-list-subscriber`: Pub/Sub トリガーで `/list` を実行（現在は bedrock のみ）— `43-pubsub-list-subscriber.yaml`
  - `bedrock-backup-cronjob`: 毎日 04:00 JST に Bedrock ワールドを MinIO へ — `bds-backup-cronjob.yaml`
    （⚠️ 2026-09 時点で失敗中: mc クライアントの配布 URL が 410）
  - `gcs-backup-cronjob`: 毎月1日 03:00 JST に Bedrock（と `JAVA_SERVERS`）を GCS へ — `35-gcs-backup-cronjob.yaml`
- **monitoring-prometheus namespace**: `vmagent`（1s scrape → mc-monitoring-1）/ `vector` DaemonSet（ログ → mc-monitoring-1）
- **本リポジトリ管理外**（触らない）: `homepage` / `misskey` / `relay` / `minecraft-data` namespace

## 接続フロー

```
Java:    Player → 35.200.78.252:25565/TCP
         → socat-tcp (GCE) → Tailscale → k3s NodePort :30065 (svc-survival)

Bedrock: Player → 35.200.78.252:19132/UDP
         → socat-bedrock (fork 透過) → Tailscale → BDS hostPort :19132
```

## Tailscale ネットワーク

```
100.107.122.45  k3s-worker-1       ← オンプレ k3s
100.121.113.37  gce-mc-monitoring  ← 監視 VM
(動的)          gce-mc-proxy       ← 入口 VM（MIG 再作成で IP が変わる）
```

## 既知の問題・制約

### Bedrock プロキシ禁止事項（ポストモーテム実証済み）
- **L7プロキシ禁止**: XUID 消失・パケット喪失が発生する（bedrock-protocol ライブラリ等）
- **Nginx Stream UDP 禁止**: ソースポート書き換えで RakNet セッションが破綻する
- → **socat fork透過 + hostPort** が唯一の正解

### Bedrock MOTD 欠落による接続不能
- world の level.dat `LANBroadcast=0` で pong から MOTD が消え接続不能になる
- vmalert `BedrockUnjoinableNoMOTD` で検知（`Documents/OperationPostmortem/postmortem-bedrock-motd-unjoinable.md`）

### Nasu Golem VV 問題（暫定対応中）
- BDS 経由でサーバー側 world_resource_packs.json に登録すると Vibrant Visuals がグレーアウト
- 暫定: world_resource_packs.json = [] でサーバー側から除外、クライアント側グローバルリソース配布

### Terraform
- state はローカル管理（`Terraform/terraform.tfstate`、リモートバックエンドなし）
- `gce/cloud-init.yaml` を変更するとインスタンステンプレート再作成 → MIG が入口 VM を REPLACE（数分ダウン）
- Proxmox VM の `tags` は provider が空白を返し続けるため `ignore_changes` で抑制済み

## ロードマップ

README.md の「📝 ロードマップ」を参照。

## k8s 運用ルール

- **Namespace:** 環境別プレフィックス（`prod-`, `dev-`, `monitoring-`）を付与が理想だが、現在稼働中クラスターは `minecraft` namespace を使用中
- **命名:** kebab-case。`<service>-<role>` 形式
- **必須Labels:** `app.kubernetes.io/name`, `component`, `managed-by`, `env`
- **PVC/CM/Secret:** `<service>-<用途>-pvc/cm/secret` 形式
- **Pod 再起動:** replicas=0 → replicas=1 の順。`rollout restart` 禁止（旧 Pod と新 Pod 並走による OOM のリスク）
