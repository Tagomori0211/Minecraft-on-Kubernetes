# GCE: Minecraft 入口プロキシ（mc-proxy）/ 監視 VM（mc-monitoring-1）

GCE 上で動く 2 台の VM の構成ファイル一式。VM 自体は Terraform（`Terraform/gce.tf` / `Terraform/monitoring.tf`）で管理する。

| VM | 役割 | 構成 |
|----|------|------|
| `mc-proxy-xxxx`（MIG `mc-proxy-mig`） | 公開エンドポイント 35.200.78.252 | e2-micro / socat で Tailscale 越しにオンプレ k3s へ透過転送 |
| `mc-monitoring-1` | 監視・通知 | e2-small / VictoriaMetrics・VictoriaLogs・Grafana・vmalert・Alertmanager |

## アーキテクチャ（mc-proxy）

```
[Player Java]    → 35.200.78.252:25565/TCP ┐  GCE mc-proxy (MIG, e2-micro, asia-northeast1-b)
                                           │  ├─ socat-tcp     TCP4-LISTEN:25565,fork → 100.107.122.45:30065
[Player Bedrock] → 35.200.78.252:19132/UDP │  ├─ socat-bedrock UDP4-LISTEN:19132,fork → 100.107.122.45:19132
                                           │  └─ tailscaled (host systemd, kernel mode)
                                           │        │
                                           └────────┼─→ Tailscale → 100.107.122.45 (k3s-worker)
                                                    │      ├─ Survival (svc-survival NodePort) :30065
                                                    │      └─ Bedrock  (deploy-bedrock hostPort) :19132
```

- MIG はサイズ 1。TCP:25565 ヘルスチェックで異常時に自動再作成（オートヒーリング）する
- インスタンス名は動的（`mc-proxy-xxxx`）。Tailscale IP（hostname `gce-mc-proxy`）も再作成で変わる
- Bedrock は RakNet を壊さないよう L7 / Nginx UDP プロキシを使わず、socat の fork 透過転送に限定している

## ファイル構成

```
gce/
├── README.md
├── compose.yaml                  # mc-proxy: socat-tcp / socat-bedrock / node-exporter / vmagent-host
├── vmagent.yml                   # mc-proxy のホストメトリクス → mc-monitoring-1 へ remote_write
├── cloud-init.yaml               # mc-proxy 初期セットアップ（gce.tf がインスタンステンプレートに埋め込む）
├── systemd/
│   ├── mc-proxy.service          # compose 起動 unit
│   └── fetch-secrets.sh          # 旧 Velocity 用 secret の取得（Secret が無ければスキップ。後述）
├── monitoring-cloud-init.yaml    # mc-monitoring-1 初期セットアップ（monitoring.tf が埋め込む）
└── monitoring/                   # mc-monitoring-1 の Docker Compose 一式（/opt/mc-monitoring に配置）
    ├── compose.yaml
    ├── vmagent-host.yml
    ├── vector/vector.yaml        # k3s Vector DaemonSet からのログ受信 → VictoriaLogs
    ├── vmalert/rules/minecraft.yml
    ├── alertmanager/alertmanager.yml
    ├── provisioning/             # Grafana データソース / ダッシュボード provider
    ├── dashboards/               # Grafana ダッシュボード JSON
    └── scripts/discord-notifier.py  # 課金アラート（Pub/Sub pull）→ Discord
```

## ⚠️ 変更時の注意

- **cloud-init は VM 作成時に本リポジトリ main ブランチの `gce/` を clone して配置する**
  （mc-proxy → `/opt/mc-proxy`、mc-monitoring-1 → `/opt/mc-monitoring`）。
  `compose.yaml` / `vmagent.yml` / `systemd/*` / `monitoring/*` を移動・改名すると、次回のオートヒーリング時に起動できなくなる。
- **`cloud-init.yaml` を 1 文字でも変更すると**、`terraform apply` でインスタンステンプレートが再作成され、
  MIG が入口 VM を REPLACE する（数分のダウンタイム）。apply は `.claude/commands/tf-safe-apply.md` の手順で行う。
- `gce/` 配下の変更は稼働中の VM には自動反映されない。反映は VM の再作成、または IAP SSH で
  `/opt/mc-proxy`（`/opt/mc-monitoring`）の該当ファイルを更新して `docker compose up -d` で行う。

## Secret Manager

| Secret | 用途 |
|--------|------|
| `tailscale-auth-key` | cloud-init の `tailscale up`（reusable / pre-approved な auth key を登録すること） |
| `mc-discord-webhook-url` | mc-monitoring-1 の `.env`（alertmanager-discord）・discord-notifier・バックアップ通知 |

- Tailscale auth key をローテしたら、`monitoring/vmalert/rules/minecraft.yml` の
  `TailscaleAuthKeyExpiringSoon` の epoch も更新する。
- `systemd/fetch-secrets.sh` は Velocity 時代の `velocity-forwarding-secret` を取得する名残。
  Secret が存在しなければスキップするため無害だが、撤去には `cloud-init.yaml` の変更（= 入口 VM 再作成）が伴う。

## 運用

### IAP SSH（gcloud は k3s-worker から実行）

```bash
# mc-proxy: 現行インスタンス名を取得してから接続
ssh -t k3s-worker 'NAME=$(gcloud compute instances list --filter="name~^mc-proxy-" --format="value(name)") && gcloud compute ssh "$NAME" --zone=asia-northeast1-b --tunnel-through-iap'

# mc-monitoring-1
ssh -t k3s-worker 'gcloud compute ssh mc-monitoring-1 --zone=asia-northeast1-b --tunnel-through-iap'
```

### VM 内での確認

```bash
# mc-proxy
sudo systemctl status mc-proxy.service             # active (exited)
sudo docker compose -f /opt/mc-proxy/compose.yaml ps
sudo docker compose -f /opt/mc-proxy/compose.yaml logs -f socat-tcp
sudo docker compose -f /opt/mc-proxy/compose.yaml logs -f socat-bedrock
tailscale ping --until-direct 100.107.122.45

# mc-monitoring-1
sudo docker compose -f /opt/mc-monitoring/compose.yaml ps

# 共通: cloud-init のブートストラップログ / Tailscale
sudo cat /var/log/cloud-init-output.log
journalctl -u tailscaled -f
```

### 外部からの疎通確認

```bash
nc -zv 35.200.78.252 25565       # Java TCP
nc -zuv 35.200.78.252 19132      # Bedrock UDP
```
