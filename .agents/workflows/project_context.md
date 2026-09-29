---
description: プロジェクト進捗管理
---

# Minecraft Hybrid Cloud Infrastructure (Minecraft-on-Kubernetes)

## 概要

GCP (GCE) とオンプレミス (k3s) を Tailscale VPN で接続した、Minecraft (Java版 / Bedrock版) のハイブリッドクラウド構成リポジトリ。
アーキテクチャの一次情報はリポジトリ直下の `README.md` と `Documents/Mermaids/*.mermaid`。

## アーキテクチャ構成

### 1. GCE: mc-gateway（`Terraform/gateway.tf` / `gce/gateway/`）

入口・監視・Status Platform を 1 台に集約した単体 VM（2026-09-30 に mc-proxy MIG / mc-monitoring-1 / tagomori-app を統合）。

- e2-micro（swap 2GB）/ pd-balanced 20GB / asia-northeast1-b / 静的IP `35.200.78.252` / SA `mc-proxy-sa`
- **systemd**
  - `mc-socat-java`: Java TCP 25565 → `100.107.122.45:30065`（survival NodePort。Java 休眠中は接続先なし）
  - `mc-socat-bedrock`: Bedrock UDP 19132 → `100.107.122.45:19132`（fork 透過転送）
  - `mc-discord-notifier`: 課金アラート（Pub/Sub `billing-alerts-gce-pull`）→ Discord
  - `prometheus-node-exporter`（127.0.0.1:9100）、`tailscaled`（hostname `gce-mc-gateway`）
- **Docker Compose（host network, `/opt/mc-gateway`）**: VictoriaMetrics（:8428, 保持14日）/
  VictoriaLogs（:9428, 保持30日）/ Grafana（:3000, Tailscale 経由のみ）/ vmalert / Alertmanager（Discord 直送）
- **Status Platform**（app.tagomori.dev）: cloud-observability-gateway リポジトリの CI が `~/app` に配置
  （cloudflared / Envoy / Ktor API / MariaDB）
- cloud-init（`gce/gateway/cloud-init.yaml`）は VM 作成時に一度だけ実行され、本リポジトリ main の `gce/gateway/` を
  `/opt/mc-gateway` に配置する。稼働中 VM への反映は IAP SSH で該当ファイルを更新して再起動する

### 2. オンプレ k3s（`k8s/onprem/`）

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
  - `gcs-backup-cronjob` / `gcs-daily-backup-cronjob`: Bedrock（と `JAVA_SERVERS`）を GCS `sushiski-mc-backups` へ
    — `35-gcs-backup-cronjob.yaml`。月次は毎月1日 03:00 JST（バケット直下・1年保持・成功/失敗を通知）、
    日次は 2〜31日 04:00 JST（`daily/`・8日で削除・失敗時のみ通知）。旧 MinIO 宛て日次ジョブは 2026-09-30 に廃止
- **monitoring-prometheus namespace**: `vmagent`（1s scrape → mc-gateway）/ `vector` DaemonSet（ログ → mc-gateway の VictoriaLogs）
- **本リポジトリ管理外**（触らない）: `homepage` / `misskey` / `relay` / `minecraft-data` namespace

## 接続フロー

```
Java:    Player → 35.200.78.252:25565/TCP
         → mc-socat-java (mc-gateway) → Tailscale → k3s NodePort :30065 (svc-survival)

Bedrock: Player → 35.200.78.252:19132/UDP
         → mc-socat-bedrock (fork 透過) → Tailscale → BDS hostPort :19132
```

## Tailscale ネットワーク

```
100.107.122.45  k3s-worker-1    ← オンプレ k3s
100.105.149.22  gce-mc-gateway  ← GCE（入口・監視。k3s の vmagent / Vector / bq-metrics の送信先）
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
- `gce/gateway/cloud-init.yaml` の変更は mc-gateway の metadata の in-place 更新のみ（再作成時にだけ効く）
- 静的IP `google_compute_address.minecraft_ip` の description は ForceNew（変更すると公開 IP が変わる）
- Proxmox VM の `tags` は provider が空白を返し続けるため `ignore_changes` で抑制済み

## ロードマップ

README.md の「📝 ロードマップ」を参照。

## k8s 運用ルール

- **Namespace:** 環境別プレフィックス（`prod-`, `dev-`, `monitoring-`）を付与が理想だが、現在稼働中クラスターは `minecraft` namespace を使用中
- **命名:** kebab-case。`<service>-<role>` 形式
- **必須Labels:** `app.kubernetes.io/name`, `component`, `managed-by`, `env`
- **PVC/CM/Secret:** `<service>-<用途>-pvc/cm/secret` 形式
- **Pod 再起動:** replicas=0 → replicas=1 の順。`rollout restart` 禁止（旧 Pod と新 Pod 並走による OOM のリスク）
