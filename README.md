# TAK Pipeline - Hybrid Cloud Minecraft Infrastructure

**ハイブリッドクラウド構成によるMinecraftサーバー基盤**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge&logo=open-source-initiative&logoColor=white)](LICENSE)
![Terraform](https://img.shields.io/badge/IaC-Terraform-%237B42BC.svg?style=for-the-badge&logo=terraform&logoColor=white)
![Ansible](https://img.shields.io/badge/Config-Ansible-%23EE0000.svg?style=for-the-badge&logo=ansible&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-k3s-%23326CE5.svg?style=for-the-badge&logo=kubernetes&logoColor=white)
![Google Cloud](https://img.shields.io/badge/GoogleCloud-GCE%20%2B%20BigQuery-%234285F4.svg?style=for-the-badge&logo=google-cloud&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-%232496ED.svg?style=for-the-badge&logo=docker&logoColor=white)
![Tailscale](https://img.shields.io/badge/Tailscale-VPN-%2354362B.svg?style=for-the-badge&logo=tailscale&logoColor=white)
![VictoriaMetrics](https://img.shields.io/badge/VictoriaMetrics-Monitoring-%23e6522c.svg?style=for-the-badge&logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-Dashboard-%23F46800.svg?style=for-the-badge&logo=grafana&logoColor=white)
![BigQuery](https://img.shields.io/badge/BigQuery-Analytics-%234285F4.svg?style=for-the-badge&logo=googlebigquery&logoColor=white)
![Hybrid Cloud](https://img.shields.io/badge/Hybrid%20Cloud-%23005571.svg?style=for-the-badge&logo=icloud&logoColor=white)
![Proxmox](https://img.shields.io/badge/Proxmox-%23E57024.svg?style=for-the-badge&logo=proxmox&logoColor=white)

---

> **Status Platform（可視化）**: 本リポの監視基盤に相乗りする可視化ダッシュボード。公開 URL: [https://app.tagomori.dev](https://app.tagomori.dev)（リポ: [cloud-observability-gateway](https://github.com/Tagomori0211/cloud-observability-gateway)）。現行リポ名のまま運用。

## 📋 プロジェクト概要

本プロジェクトは、**オンプレミス（自宅サーバー）と Google Compute Engine を Tailscale VPN で接続**し、コスト効率と可用性を両立させた Minecraft サーバー基盤です。

Java版・Bedrock版の両対応に加え、**VictoriaMetrics + Grafana によるメトリクス可観測性**、**VictoriaLogs + Vector によるログ集約**、**BigQuery によるコスト・運用メトリクス分析**、**Discord による通知統合** までを Infrastructure as Code（IaC）で完全管理しています。

> **History**: 2026/05/03 に GKE クラスターから GCE VM 構成へ移行（コスト削減）。2026/05/07-08 に監視スタックを k3s 内 Prometheus から GCE 専用 VM 上の VictoriaMetrics + Grafana に再構築。2026/06 に VictoriaLogs + Vector ログパイプラインを追加し、メトリクス収集を 1 秒解像度へ、BigQuery 集積を k3s Pod（15 秒解像度）へ再設計。

### 🎯 設計思想

| 観点 | アプローチ |
|------|-----------|
| **コスト最適化** | エントリポイントのみ GCE / 重量級ワークロードはオンプレに集約、クラウドは最小限リソース |
| **可用性** | クラウド側プロキシで世界中からの常時アクセスを保証 |
| **運用効率** | Terraform / Ansible / Kubernetes マニフェストで完全宣言的管理 |
| **セキュリティ** | Tailscale ゼロトラストネットワーク・公開ポートを最小化 |
| **可観測性** | メトリクス（vmagent → VictoriaMetrics）+ ログ（Vector → VictoriaLogs）を Grafana / BigQuery へ集約 |
| **通知統合** | 課金アラート・バックアップ完了・オンプレ沈黙検知を Discord に集約 |

---

## 🏗️ アーキテクチャ

### ゲームトラフィック
```mermaid
%%{init: {'theme':'dark', 'themeVariables': {
  'lineColor':'#94a3b8'
}}}%%
flowchart LR
subgraph Legend["GameTraffic Architecture"]
    %% ───────────── プレイヤー ─────────────
    Player_Java["☕ Java版プレイヤー<br/><b>25565/TCP</b>"]
    Player_Bedrock["🪨 Bedrock版プレイヤー<br/><b>19132/UDP</b>"]

    %% ───────────── GCE エントランス ─────────────
    subgraph GCE["☁️ GCE エントランス : e2-micro / 1GB"]
        direction TB
        subgraph Compose["🐳 Docker Compose — host network"]
            SocatTCP["socat-tcp<br/>TCP4-LISTEN:25565,fork<br/>→ 100.107.122.45:30065"]
            SocatUDP["socat-bedrock<br/>UDP4-LISTEN:19132,fork<br/>→ 100.107.122.45:19132"]
        end
        TailscaledGCE["🔐 tailscaled (systemd)<br/>gce-mc-proxy : 100.124.222.31"]
    end

    %% ───────────── Tailscale VPN ─────────────
    subgraph TS["🛡️ Tailscale VPN (WireGuard)"]
        TS_Net["暗号化トンネル<br/>Direct < 1ms"]
    end

    %% ───────────── オンプレ k3s ─────────────
    subgraph Onprem["🏠 オンプレミス : Ryzen 5700G / 64GB"]
        TailscaledK3s["🔐 tailscaled (host)<br/>k3s-worker-1 : 100.107.122.45"]
        subgraph K3s["⎈ k3s クラスタ — namespace: minecraft"]
            direction TB
            subgraph Survival["☕ deploy-survival — Port 30065 / 30Gi"]
                direction TB
                SvMc["minecraft<br/>itzg/minecraft-server<br/>NeoForge 21.1.228 (REV17)"]

            end
            subgraph Bedrock["🪨 deploy-bedrock — Port 19132 / 8Gi"]
                direction TB
                BdSrv["bedrock<br/>itzg/minecraft-bedrock-server"]

            end

        end
    end
end

    %% ───────────── データフロー ─────────────
    Player_Java    -->|"25565/TCP"| SocatTCP
    Player_Bedrock -->|"19132/UDP"| SocatUDP

    SocatTCP -->|":30065"| TailscaledGCE
    SocatUDP -->|"UDP fork"| TailscaledGCE
    TailscaledGCE <-->|"Direct"| TS_Net
    TS_Net <-->|"暗号化"| TailscaledK3s

    TailscaledK3s -->|":30065"| Survival
    TailscaledK3s -->|":19132"| Bedrock



    %% ───────────── スタイル ─────────────
    classDef player    fill:#b91c1c,color:#fff,stroke:#0369a1,stroke-width:2px;
    classDef playerBed fill:#15803d,color:#fff,stroke:#3f6212,stroke-width:2px;
    classDef socat     fill:#0d9488,color:#fff,stroke:#0f766e,stroke-width:1.5px;
    classDef tsnode    fill:#7c3aed,color:#fff,stroke:#5b21b6,stroke-width:1.5px;
    classDef tsnet     fill:#312e81,color:#fff,stroke:#a5b4fc,stroke-width:1.5px;
    classDef svComp    fill:#b91c1c,color:#fff,stroke:#7f1d1d,stroke-width:1.5px;
    classDef bdComp    fill:#15803d,color:#fff,stroke:#14532d,stroke-width:1.5px;
    classDef ext       fill:#1e293b,color:#e2e8f0,stroke:#64748b,stroke-width:1.5px;

    class Player_Java player;
    class Player_Bedrock playerBed;
    class SocatTCP,SocatUDP socat;
    class TailscaledGCE,TailscaledK3s tsnode;
    class TS_Net tsnet;
    class SvMc,SvMon,SvLog svComp;
    class BdSrv,BdMon bdComp;
    
    style GCE        fill:#23237d,color:#ffffff,stroke:#2563eb,stroke-width:3px;
    style Compose    fill:#bfdbfe,color:#1e3a8a,stroke:#3b82f6,stroke-width:2px;
    style TS         fill:#ede9fe,color:#4c1d95,stroke:#7c3aed,stroke-width:3px;
    style Onprem     fill:#442222,color:#ffffff,stroke:#443333,stroke-width:3px;
    style K3s        fill:#14A65F,color:#ffffff,stroke:#fff,stroke-width:2px;
    style Survival   fill:#fee2e2,color:#7f1d1d,stroke:#dc2626,stroke-width:2px;
    style Bedrock    fill:#dcfce7,color:#14532d,stroke:#16a34a,stroke-width:2px;
    style Legend     fill:#222222,color:#ffffff,stroke:#ffffff,stroke-width:3px;

```

### 監視・通知系
```mermaid

flowchart LR
    subgraph K3s["k3s-worker VM (オンプレ)"]
        MC_Pods["Minecraft Pods (ClusterIP :8080)<br>minecraft-exporter<br>Java:survival / BE:bedrock"]
        VMAgent["vmagent<br>収集エージェント<br>scrape間隔 1s"]
        BQ_Job["BQ挿入ジョブPod<br>VMへクエリ<br>15s解像度でサンプリング挿入"]
        VectorDS["Vector DaemonSet<br>minecraft namespace<br>Podログ読取"]
        MC_Pods -->|scrape| VMAgent
        MC_Pods -.->|ログ| VectorDS
    end

    subgraph GCE_Mon["GCE: mc-monitoring-1 (e2-small)<br>Docker-compose"]
        VM["VictoriaMetrics<br>8428 / 保持 14日<br>(長期は BQ)"]
        VLogs["VictoriaLogs<br>9428 / 保持 30日"]
        VectorAgg["Vector Aggregator<br>:9001"]
        Grafana["Grafana<br>(アクセスはTailscale経由のみ)"]
        VMAlert["vmalert<br>ルール評価 30s<br>沈黙/Down/scrape/鍵期限"]
        AM["Alertmanager<br>:9093"]
        AMD["alertmanager-discord<br>ブリッジ"]
        Alert_Job["discord-notifier<br>課金 5分pull"]
    end

    subgraph GCP_Svc["GCP マネージドサービス"]
        PubSub["Pub/Sub<br>alerts<br>(pull subscription)"]
        Budget["課金予算アラート<br>80%/90%/100%発火"]
        BQ[("BigQuery<br>minecraft_monitoring<br>server_metrics")]
    end

    Admin["🔧 管理者"]
    Discord["💬 Discord"]

    VMAgent -->|remote_write| VM
    VM --> Grafana
    VM --> BQ_Job

    VectorDS -->|Tailscale :9001| VectorAgg
    VectorAgg -->|Loki API push| VLogs
    VLogs --> Grafana
    Grafana --> Admin

    VM -->|ルール評価| VMAlert
    VMAlert -->|発火| AM
    AM -->|webhook| AMD
    AMD -->|Discord embed| Discord

    Budget --> PubSub
    PubSub -->|課金アラート| Alert_Job
    BQ_Job -->|15s insert| BQ

    Alert_Job -->|課金超過アラート| Discord

    style K3s        fill:#C62828,color:#fff
    style MC_Pods    fill:#424242,color:#fff,stroke:#f87171
    style VMAgent    fill:#e6522c,color:#fff
    style VectorDS   fill:#08b3a6,color:#fff
    style GCE_Mon    fill:#0F9D58,color:#fff,stroke:#fff,stroke-width:2px
    style VM         fill:#e6522c,color:#fff
    style VLogs      fill:#a259ff,color:#fff
    style VectorAgg  fill:#08b3a6,color:#fff
    style Grafana    fill:#f46800,color:#fff
    style BQ_Job     fill:#4285F4,color:#fff
    style VMAlert    fill:#e6522c,color:#fff
    style AM         fill:#e6522c,color:#fff
    style AMD        fill:#5865F2,color:#fff
    style Alert_Job  fill:#7F52FF,color:#fff
    style GCP_Svc    fill:#2962FF,color:#fff,stroke:#82B1FF
    style BQ         fill:#123564,color:#fff
    style PubSub     fill:#E65100,color:#fff
    style Budget     fill:#F57F17,color:#fff
    style Admin      fill:#37474F,color:#fff
    style Discord    fill:#5865F2,color:#fff

```

---

## 🛠️ 技術スタック

### Infrastructure as Code

| ツール | バージョン | 用途 |
|--------|-----------|------|
| **Terraform** | >= 1.5.0 | GCE / VPC / IAM / BigQuery / Pub/Sub / Budget / Proxmox VM |
| **Ansible** | - | k3s + Tailscale インストール、Minecraft マニフェストデプロイ |
| **Kubernetes** | k3s v1.31 | オンプレ Minecraft サーバーのコンテナオーケストレーション |
| **Docker Compose** | - | mc-proxy-1: socat-tcp / socat-bedrock、mc-monitoring-1: VictoriaMetrics / VictoriaLogs / Vector / Grafana |

### クラウド・インフラ

| サービス | 用途 |
|---------|------|
| **GCE: mc-proxy-1** (e2-micro) | socat-tcp（Java 25565）+ socat-bedrock（Bedrock 19132）の透過プロキシ |
| **GCE: mc-monitoring-1** (e2-small) | VictoriaMetrics + VictoriaLogs + Vector + Grafana + vmalert + Alertmanager + alertmanager-discord + discord-notifier（Tailscale 経由のみアクセス可） |
| **BigQuery** | メトリクス時系列保存（k3s Pod が 15 秒解像度で INSERT）・課金 Export・コスト按分 VIEW |
| **Cloud Storage** (Standard) | 月次ワールドバックアップ（lifecycle: 31日 ARCHIVE / 365日削除） |
| **Pub/Sub** | 課金アラート（GCP Budget イベント駆動） |
| **Cloud Billing Budget** | 80% / 90% / 100% でTopic配信 |
| **Secret Manager** | Tailscale auth-key / Discord Webhook URL / Player hash salt |
| **Proxmox VE** | オンプレミス仮想化基盤（Ryzen 5700G / 64GB） |
| **Tailscale** | メッシュVPN（ゼロトラスト） |

### アプリケーション

| コンポーネント | イメージ |
|---------------|---------|
| socat (Java TCP / Bedrock UDP) | `alpine/socat` |
| Survival | `itzg/minecraft-server`  |
| Bedrock Server | `itzg/minecraft-bedrock-server` |
| Metrics Exporter | `itzg/mc-monitor` |
| VictoriaMetrics | `victoriametrics/victoria-metrics:v1.115.0` |
| vmagent | `victoriametrics/vmagent:v1.115.0` |
| VictoriaLogs | `victoriametrics/victoria-logs:v1.24.0-victorialogs` |
| Vector | `timberio/vector:0.56.0-debian` |
| vmalert | `victoriametrics/vmalert:v1.115.0` |
| Alertmanager | `prom/alertmanager:v0.27.0` |
| Alertmanager→Discord ブリッジ | `benjojo/alertmanager-discord` |
| Grafana | `grafana/grafana:11.6.1` |

---

## ⚙️ 主要な設計ポイント

### 1. クラウド・オンプレ責任分担

```text
[ Internet ]
    │
    │ 25565/TCP, 19132/UDP
    ▼
[ GCE: mc-proxy-1 ]  ← 静的IP 35.200.78.252、24/365 公開エンドポイント
    │  Docker Compose: socat-tcp (Java) + socat-bedrock (Bedrock)
    │
    │ Tailscale 暗号化トンネル ≈ 20ms direct
    ▼
[ オンプレ k3s-worker (Ryzen 5700G / 64GB) ]
    └─ Survival（NeoForge 統合）/ Bedrock BDS（合計 46Gi JVM Request）
```

「公開・薄いプロキシ層、可観測性の高い監視ノード」と「重量級ワークロード」を明確に分離。クラウド側は VM 2台（エントランス + 監視）に抑え、メモリ集約型のゲームサーバーをオンプレに寄せている。Velocity / nginx-stream は撤去済みで、Java は socat-tcp が NodePort へ直結する。

### 2. Bedrock UDP の透過転送（socat）

```yaml
# gce/compose.yaml
socat-bedrock:
  image: alpine/socat:latest
  network_mode: host
  command:
    - "UDP4-LISTEN:19132,fork,reuseaddr"
    - "UDP4:100.107.122.45:19132"
```

Bedrock の RakNet は L7 プロキシで壊れるため、`fork` オプションでクライアント毎に独立 UDP ソケットを生成し Tailscale 経由で k3s `hostPort` まで一切改変せず透過転送。Java 側も同じく `socat-tcp`（`TCP4-LISTEN:25565,fork` → `100.107.122.45:30065`）で svc-survival の NodePort へ直結しており、Velocity / nginx-stream といった中間プロキシ層を撤去している。

### 3. Tailscale ゼロトラストネットワーク

3 ノードのメッシュ構成:

| ホスト名 | Tailscale IP | 役割 |
|---|---|---|
| `gce-mc-proxy` | 100.124.222.31 | エッジプロキシ（公開エンドポイント） |
| `gce-mc-monitoring` | 100.121.113.37 | VictoriaMetrics / Grafana |
| `k3s-worker` | 100.107.122.45 | ゲームサーバー Pod |

GCE 側は `tailscaled` を host systemd（kernel mode）で起動。auth key は Secret Manager から `cloud-init` 起動時に取得。Grafana は `0.0.0.0:3000` でリッスンするが GCE ファイアウォールで未開放のため、Tailscale ピアからのみ到達可能。

### 4. 監視スタック (VictoriaMetrics + VictoriaLogs + Grafana)

```text
[ k3s vmagent ]                       [ k3s Vector DaemonSet ]
    │ scrape 1s                            │ minecraft namespace の Pod ログ
    │ (Minecraft / k8s nodes / cAdvisor)   │ read /var/log/pods
    │ remote_write via Tailscale           │ vector protocol v2 via Tailscale
    ▼                                      ▼
[ GCE mc-monitoring-1 ]
    ├── VictoriaMetrics :8428 （保持 14日 / -memory.allowedPercent=40・1s 高解像度のため短縮、長期は BQ）
    ├── VictoriaLogs   :9428 （保持 30日 / -memory.allowedPercent=20）
    ├── Vector Aggregator :9001 → VictoriaLogs（Loki API push）
    └── Grafana :3000 （Tailscale 経由のみ・provisioning でデータソース／ダッシュボード自動投入）
```

- `gce/monitoring/compose.yaml`: VictoriaMetrics + VictoriaLogs + Vector + Grafana を Docker Compose で起動
- `gce/monitoring/vector/vector.yaml`: Vector Aggregator 設定（sink: VictoriaLogs）
- `gce/monitoring/provisioning/datasources/`: Grafana に VictoriaMetrics / VictoriaLogs データソースを自動投入
- `gce/monitoring/dashboards/minecraft-java-overview.json`: Java 各ワールドの稼働状態・プレイヤー数・応答時間・Pod リソース可視化
- `k8s/onprem/30-victoria-metrics.yaml`: vmagent + RBAC（ClusterRole で nodes/cAdvisor scrape 権限、scrape_interval 1s）
- `k8s/onprem/42-vector-daemonset.yaml`: Vector DaemonSet（minecraft namespace のログを Tailscale 経由で集約）

### 5. BigQuery メトリクス収集

k3s 内の **BQ 挿入ジョブ Pod** が VictoriaMetrics（1 秒解像度）へクエリを投げ、**15 秒解像度にサンプリング**して BigQuery へストリーミング INSERT する。VM=1s / BQ=15s の二段集積構成。

```text
[ VictoriaMetrics :8428（1s 解像度） ]
        │ PromQL query
        ▼
[ k3s BQ 挿入ジョブ Pod ] ── 15s サンプリング ──▶ [ BigQuery server_metrics ]
```

- `Terraform/minecraft_monitoring.tf`: dataset `minecraft_monitoring` / table `server_metrics`（DAY パーティション + clustering=[server, metric_name]）
- `k8s/onprem/` BQ 挿入ジョブ: stdlib のみ・ADC override（`CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`、SA キー作成禁止 org policy 対応）・`avg_over_time` / `max_over_time` で 15 秒集計
- BigQuery `gcp_billing_export` × `server_metrics` を JOIN した **`cost_analysis_view`** によりプレイヤー比率で按分したコスト分析が可能（Looker Studio 接続向け）

### 6. メトリクスアラート（vmalert + Alertmanager）

メトリクス由来のアラートは **vmalert → Alertmanager → Discord** の標準構成に統一。Discord はネイティブ receiver が無く `/slack` 互換は attachment を弾くため、**alertmanager-discord ブリッジ**で Discord ネイティブ embed に変換する。

```text
[ VictoriaMetrics ] ──評価(30s)──▶ [ vmalert ] ──発火──▶ [ Alertmanager :9093 ]
                                                              │ webhook
                                                              ▼
                                               [ alertmanager-discord ] ──▶ Discord embed
```

- `gce/monitoring/vmalert/rules/minecraft.yml`: `OnpremSilence`（オンプレ沈黙）/ `MinecraftServerDown` / `ScrapeTargetDown` / `TailscaleAuthKeyExpiringSoon`（鍵発行+80日）
- `gce/monitoring/alertmanager/alertmanager.yml`: `webhook_configs` → ブリッジ。webhook URL は Secret Manager から cloud-init が `.env`（`DISCORD_WEBHOOK`）生成
- **オンプレ沈黙検知**は旧 HealthCheck コンテナを廃し `OnpremSilence`（`absent(up{location="onprem"}==1)` 5分）ルールへ集約

### 7. 課金アラート（Pub/Sub Pull）

課金（GCP Budget）はメトリクスでなくイベント駆動のため、**mc-monitoring-1 上の discord-notifier (5 分 pull)** が Pub/Sub から取得して Discord 通知する（vmalert 対象外）。Cloud Functions push は Cloudflare の ASN ブロックで 403 になるため pull 構成。

```text
[ Cloud Billing Budget ¥8,000/月 ] ─80/90/100%─▶ [ Pub/Sub ] ◀─pull(5min)─ [ discord-notifier ] ─▶ Discord
```

- `Terraform/notifications.tf`: Pub/Sub topic + pull subscription + Budget + Secret Manager
- 月次バックアップ完了時にも `gcs-backup-cronjob` が **署名付き URL（7日有効）** 付き embed を Discord に送信

### 8. GCS Standard バックアップ

```yaml
# Terraform/gcs_backup.tf
storage_class = "STANDARD"
location      = "ASIA-NORTHEAST1"
lifecycle_rule {
  age = 31  → ARCHIVE
  age = 365 → 削除
}
```

k3s の `gcs-backup-cronjob`（毎月1日 03:00 JST）が Survival / Bedrock の各ワールドを `tar.gz` 化して GCS にアップロード。署名付き URL 生成には `mc-proxy-sa` への `roles/iam.serviceAccountTokenCreator` 委譲を Terraform で設定済み。

### 9. Secret 管理

Secret Manager で以下を管理:

| Secret 名 | 用途 |
|---|---|
| `tailscale-auth-key` | mc-proxy-1 / mc-monitoring-1 の cloud-init で `tailscale up` |
| `mc-discord-webhook-url` | 課金アラート・バックアップ通知の Webhook |
| `mc-player-hash-salt` | プレイヤー XUID の SHA256 ハッシュ用 256-bit salt（`Terraform/privacy.tf`） |

ハードコードを徹底排除し、SA に最小権限の `roles/secretmanager.secretAccessor` のみ付与。

---

## 💰 コスト削減実績

### アーキテクチャ進化

| フェーズ | 構成 | 月額コスト | 備考 |
|---|---|---:|---|
| Phase 0: 全クラウド見込み | 全コンポーネント GKE 上 | 約 35,000 円 | 当初試算（未実装） |
| Phase 1: GKE Hybrid | GKE Standard + オンプレ k3s | 約 19,700 円 | Phantom LB / Cloud NAT 等を含む |
| Phase 2: GCE 移行 (2026/05/03) | GCE mc-proxy-1 + オンプレ k3s | 約 3,680 円 | GKE 削除・LB 統合・NAT 廃止 |
| **Phase 3: 可観測性追加 (現在)** | **+ mc-monitoring-1 + BQ + Pub/Sub** | **約 7,000 円** | **監視 VM・課金予算 ¥8,000/月** |

主な削減要因:
- **GKE 削除**: コントロールプレーン費用・Phantom LB（¥2,700）・Cloud NAT（¥4,500）・nginx-gw-bedrock LB（¥2,700）が消滅
- **LB 統合**: Java/Bedrock 別 IP（¥2,700×2）→ 単一静的 IP 35.200.78.252
- **メモリ集約**: 高価なクラウドメモリを回避し JVM プロセスをオンプレ Ryzen 5700G / 64GB に集約

### VPS との比較（参考: 2026年5月時点・税込）

同等のゲーム機能（Survival〔NeoForge 統合 MOD〕+ Bedrock BDS = 約 18〜24GB メモリ）を国内 VPS で構築した場合:

| 構成 | 月額 | 年額 | 現構成との差 |
|---|---:|---:|---:|
| **🏆 現構成 (GCE Hybrid)** | **約 7,000 円** | **約 84,000 円** | 基準 |
| Xserver VPS 24GB（36ヶ月契約） | 7,200 円 | 86,400 円 | +2,400 円/年 |
| Xserver VPS 12GB + 24GB（思想維持） | 10,800 円 | 129,600 円 | +45,600 円/年 |
| さくらVPS 32G（12ヶ月一括） | 26,400 円 | 316,800 円 | +232,800 円/年 |

シングル VPS とほぼ同価格帯で「Terraform 管理・k3s・Tailscale ゼロトラスト・VictoriaMetrics 監視・BigQuery コスト分析・Discord 通知一式」を実現している。

#### 真の TCO（オンプレ運用の隠れコストを含む）

| 項目 | 月額換算 |
|---|---:|
| 電気代（Ryzen 5700G 60W 平均 / 30円/kWh） | 約 1,290 円 |
| ハードウェア減価償却（取得 15万円 / 36ヶ月） | 約 4,170 円 |
| 自宅 10GbE 回線（按分） | 約 1,000 円 |
| **クラウド支出** | **約 7,000 円** |
| **真の TCO 合計** | **約 13,460 円/月** |

---

## 📊 実証された成果

| 指標 | 結果 |
|------|------|
| **月間クラウド支出** | 約 ¥7,000（mc-proxy-1 + mc-monitoring-1 + BQ + Pub/Sub）|
| **グローバル遅延** | Tailscale Direct ≈ 20ms（東京リージョン経由）|
| **デプロイ時間** | Terraform `apply` 約 5 分（VM プロビジョニング + cloud-init） |
| **観測サイクル** | scrape 1秒（VM）/ BQ 集積 15秒 / Discord pull 5分 / 沈黙検知 5分 |
| **バックアップ** | 月次 GCS Standard + 日次 Bedrock バックアップ（CronJob） |
| **コスト分析粒度** | プレイヤー比率按分（cost_analysis_view）|

---

## 📝 ロードマップ

### ✅ 完了（2026年5月）

- GKE → GCE 移行・LB 統合・NAT 廃止
- Velocity / nginx-stream 撤去（Java は socat-tcp → NodePort 直結）
- VictoriaMetrics + Grafana スタックを GCE 専用 VM へ移行
- BigQuery `cost_analysis_view`（課金 Export × server_metrics 日次 JOIN）
- GCS バックアップを STANDARD 化（毎月1日・lifecycle 31日 ARCHIVE / 365日削除）
- 課金アラート Discord 通知（Pub/Sub pull subscription）
- 月次バックアップ Discord 通知（署名付き URL 7日有効）
- プライバシー設計（player_hash_salt by Secret Manager）

### ✅ 完了（2026年6月）

- VictoriaLogs + Vector ログ収集パイプライン追加（minecraft namespace のログを Grafana へ集約）
- メトリクス収集を 1 秒解像度へ・BigQuery 集積を k3s Pod（15 秒解像度）へ再設計
- mc-proxy を autohealing MIG 化（TCP:25565 ヘルスチェック・静的IP 維持）
- メトリクスアラートを vmalert + Alertmanager + alertmanager-discord に統一（オンプレ沈黙は vmalert ルール化、課金は Pub/Sub 継続）
- [Status Platform](https://github.com/Tagomori0211/cloud-observability-gateway) : Kotlin API + Flutter Web + Envoy + Cloudflare Tunnel
### 🔲 今後

- [ ] **Looker Studio ダッシュボード**: cost_analysis_view を基にした公開向けレポート
- [ ] **External Secrets Operator**: k3s Secret 管理の外部化

- [ ] **Disaster Recovery 手順**: バックアップからのリストア演習・runbook 文書化
- [ ] **Argo CD 導入**: k3s マニフェストの GitOps 化

---

## 📜 ライセンス

MIT License - 詳細は [LICENSE](LICENSE) を参照

---

## 👤 Author

**HN: 田籠 勇吉 (Tagomori Yukichi)**

- GitHub: [@tagomori0211](https://github.com/tagomori0211)
- Portfolio: インフラエンジニア / SRE志望

---

> **Note**: 本プロジェクトは、クラウドとオンプレミスのハイブリッド構成における
> Infrastructure as Code の実践的なポートフォリオとして構築されました。
