# GCE: mc-gateway（入口・監視・Status Platform を集約した単体 VM）

GCE の VM はこの 1 台だけで、Terraform（`Terraform/gateway.tf`）で管理する。

## 構成（mc-gateway）

```
[Player Java]    → 35.200.78.252:25565/TCP ┐  GCE mc-gateway (e2-micro, asia-northeast1-b, 単体 VM)
[Player Bedrock] → 35.200.78.252:19132/UDP │  ├─ systemd
                                           │  │   ├─ mc-socat-java     TCP4-LISTEN:25565,fork → 100.107.122.45:30065
                                           │  │   ├─ mc-socat-bedrock  UDP4-LISTEN:19132,fork → 100.107.122.45:19132
                                           │  │   ├─ mc-discord-notifier（課金アラート Pub/Sub pull → Discord）
                                           │  │   ├─ prometheus-node-exporter（127.0.0.1:9100）
                                           │  │   └─ tailscaled（gce-mc-gateway）
                                           │  ├─ docker compose（/opt/mc-gateway、host network）
                                           │  │   ├─ VictoriaMetrics :8428 ← k3s vmagent / bq-metrics / Status Platform
                                           │  │   ├─ VictoriaLogs    :9428 ← k3s Vector DaemonSet（Loki push）
                                           │  │   ├─ Grafana         :3000（Tailscale 経由のみ）
                                           │  │   └─ vmalert → Alertmanager → Discord（ネイティブ discord_configs）
                                           │  └─ Status Platform（~/app、cloud-observability-gateway の CI が配置）
                                           │       cloudflared / Envoy / Ktor API / MariaDB
                                           └──→ Tailscale → 100.107.122.45 (k3s-worker)
```

- 入口の socat は Docker に依存せず systemd で動かし、`OOMScoreAdjust=-900` でメモリ逼迫時も最後まで残す
- 監視スタックの各コンテナには `mem_limit` を設定している（e2-micro の 1GB + swap 2GB で同居）
- 足りなければ `Terraform/variables.tf` の `gateway_machine_type` を e2-small に上げる（停止を伴う in-place 更新）
- 単体 VM のため、ブートディスク上の監視データ・MariaDB・Tailscale ノード状態は再起動しても保持される

## ファイル構成（gce/gateway/ → /opt/mc-gateway）

```
gce/gateway/
├── cloud-init.yaml               # 初期セットアップ（Terraform/gateway.tf が user-data に埋め込む）
├── compose.yaml                  # 監視スタック
├── victoria-metrics/scrape.yml   # node-exporter の scrape 設定
├── vmalert/rules/minecraft.yml   # アラートルール
├── alertmanager/alertmanager.yml # Discord 通知（webhook は secrets/discord_webhook）
├── grafana/provisioning/         # データソース / ダッシュボード provider
├── grafana/dashboards/           # ダッシュボード JSON
├── scripts/discord-notifier.py   # 課金アラート通知
└── systemd/                      # socat ×2・課金通知・監視スタックの unit
```

## ⚠️ 変更時の注意

- `cloud-init.yaml` は VM 作成時に一度だけ実行される。稼働中の VM に反映するには、IAP SSH で `/opt/mc-gateway` の
  該当ファイルを更新し、`sudo systemctl restart <unit>` または `sudo docker compose up -d` で再起動する。
- `Terraform/gateway.tf` の `user-data` 変更は in-place 更新（再作成なし）で、次回の再作成時にだけ効く。

## Secret Manager

| Secret | 用途 |
|--------|------|
| `tailscale-auth-key` | cloud-init の `tailscale up`（有効期限内・再利用可能な auth key を登録しておくこと） |
| `mc-discord-webhook-url` | Alertmanager（`secrets/discord_webhook`）・課金通知・バックアップ通知 |
| `tagomori-tunnel-token` | Status Platform の cloudflared（CI が `~/app/.env` に配置） |

Tailscale auth key をローテしたら、`gateway/vmalert/rules/minecraft.yml` の `TailscaleAuthKeyExpiringSoon` の epoch も更新する。

## 運用

```bash
# IAP SSH（gcloud は k3s-worker から実行）
ssh -t k3s-worker 'gcloud compute ssh mc-gateway --zone=asia-northeast1-b --tunnel-through-iap'

# VM 内
systemctl status mc-socat-java mc-socat-bedrock mc-discord-notifier
sudo docker compose -f /opt/mc-gateway/compose.yaml ps
journalctl -u mc-socat-bedrock -f
tailscale ping --until-direct 100.107.122.45
sudo cat /var/log/cloud-init-output.log

# 外部からの疎通確認
nc -zv 35.200.78.252 25565       # Java TCP
nc -zuv 35.200.78.252 19132      # Bedrock UDP
```
