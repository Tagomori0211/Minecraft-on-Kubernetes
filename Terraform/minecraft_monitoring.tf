# ============================================================
# Minecraft Monitoring - BigQuery Dataset / Table
# ============================================================
# フロー:
#   VictoriaMetrics(1s) → k3s Deployment bq-metrics (15秒解像度サンプリング)
#   → bq insert → BigQuery → Looker Studio で gcp_billing_export と JOIN
#
# 認証方式:
#   SA key 作成は org policy (constraints/iam.disableServiceAccountKeyCreation)
#   で禁止されているため、k3s Pod は gcs-backup と同じ cred-file を再利用し
#   mc-proxy-sa をインパーソネートして BigQuery dataEditor 権限で INSERT する
#   （k8s/onprem/40-bq-metrics.yaml）。
# ============================================================

# ============================================================
# BigQuery Dataset
# ============================================================

resource "google_bigquery_dataset" "minecraft_monitoring" {
  project       = var.project_id
  dataset_id    = "minecraft_monitoring"
  friendly_name = "Minecraft Monitoring Metrics"
  description   = "Minecraft サーバーメトリクス（vmalert 15分集計値）。gcp_billing_export との JOIN でプレイヤー当たりコスト計算に利用。"
  location      = "US"

  labels = merge(local.common_labels, {
    purpose = "minecraft-monitoring"
  })

  depends_on = [google_project_service.bigquery]
}

# ============================================================
# BigQuery Table
# ============================================================

resource "google_bigquery_table" "server_metrics" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.minecraft_monitoring.dataset_id
  table_id   = "server_metrics"

  schema = jsonencode([
    { name = "timestamp", type = "TIMESTAMP", mode = "REQUIRED",
    description = "メトリクス収集時刻 (UTC)" },
    { name = "player_hash", type = "STRING", mode = "NULLABLE",
    description = "SHA256(XUID + salt) — 将来のプレイヤー粒度メトリクス用。現在は NULL。" },
    { name = "server", type = "STRING", mode = "REQUIRED",
    description = "サーバー識別子 (lobby / survival / mod / bedrock)" },
    { name = "metric_name", type = "STRING", mode = "REQUIRED",
    description = "recording rule 名 (例: mc:players_online:avg15m)" },
    { name = "value", type = "FLOAT64", mode = "REQUIRED",
    description = "集計値" },
  ])

  # 日次パーティション: クエリコスト削減
  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  # クラスタリング: server/metric_name フィルタを高速化
  clustering = ["server", "metric_name"]

  labels = merge(local.common_labels, {
    purpose = "minecraft-monitoring"
  })
}

# ============================================================
# BQ 権限: 既存の mc-proxy-sa に dataEditor を付与
# ============================================================
# k3s bq-metrics Pod が mc-proxy-sa をインパーソネートして INSERT する（ファイル冒頭参照）。
# dataset レベルのみ（project-wide 権限を避ける）。

resource "google_bigquery_dataset_iam_member" "mc_proxy_bq_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.minecraft_monitoring.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.mc_proxy_sa.email}"
}

# ============================================================
# BigQuery VIEW: コスト分析（Billing Export × Server Metrics）
# ============================================================
# gcp_billing_export × minecraft_monitoring.server_metrics を日次で JOIN し
# サーバー別コスト按分・プレイヤーあたりコストを算出する。
#
# NOTE: server_metrics は VictoriaMetrics → k3s bq-metrics Deployment が稼働して
#       初めてデータが入る。billing_export 側は 2026-03-01〜 のデータあり。
#       双方にデータが揃った日付から JOIN 結果が出る。
# 入力: bq-metrics（k8s/onprem/40-bq-metrics.yaml）が INSERT する 15 秒系列
#       mc:players_online:avg15s / max15s、mc:response_time_seconds:avg15s、mc:healthy:min15s
# 費用列は課金エクスポートの通貨（currency 列。本アカウントは JPY）で出力する。
# プレイヤー 0 人の日は按分列が NULL になる（SAFE_DIVIDE）。

resource "google_bigquery_table" "cost_analysis_view" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.minecraft_monitoring.dataset_id
  table_id            = "cost_analysis_view"
  deletion_protection = false

  view {
    use_legacy_sql = false
    query          = <<-SQL
      WITH

      -- 日次 GCP 総コスト（全サービス合計・課金エクスポートの通貨）
      daily_billing AS (
        SELECT
          DATE(usage_start_time)   AS usage_date,
          currency,
          service.description      AS service_name,
          SUM(cost)                AS cost
        FROM `${var.project_id}.gcp_billing_export.gcp_billing_export_v1_01D081_BB268A_137D65`
        WHERE cost > 0
        GROUP BY 1, 2, 3
      ),

      daily_total_cost AS (
        SELECT
          usage_date,
          currency,
          SUM(cost) AS total_cost
        FROM daily_billing
        GROUP BY 1, 2
      ),

      -- bq-metrics の 15 秒サンプルを日次集計（server 別）
      daily_players AS (
        SELECT
          DATE(timestamp)                                                                 AS usage_date,
          server,
          AVG(CASE WHEN metric_name = 'mc:players_online:avg15s'         THEN value END)  AS avg_players,
          MAX(CASE WHEN metric_name = 'mc:players_online:max15s'         THEN value END)  AS peak_players,
          AVG(CASE WHEN metric_name = 'mc:response_time_seconds:avg15s'  THEN value END)
            * 1000                                                                        AS avg_response_ms,
          AVG(CASE WHEN metric_name = 'mc:healthy:min15s'                THEN value END)  AS availability_ratio
        FROM `${var.project_id}.minecraft_monitoring.server_metrics`
        GROUP BY 1, 2
      ),

      -- 全サーバー合計プレイヤー数（コスト按分の分母）
      daily_total_players AS (
        SELECT
          usage_date,
          SUM(avg_players) AS total_avg_players
        FROM daily_players
        GROUP BY 1
      )

      SELECT
        dp.usage_date,
        dp.server,
        ROUND(dp.avg_players,  2)          AS avg_players_daily,
        ROUND(dp.peak_players, 0)          AS peak_players_daily,
        ROUND(dp.avg_response_ms, 1)       AS avg_response_ms_daily,
        ROUND(dp.availability_ratio, 4)    AS availability_ratio_daily,
        dtc.currency,
        ROUND(dtc.total_cost, 2)           AS daily_gcp_cost,
        -- プレイヤー比率でサーバー別にコストを按分
        ROUND(
          SAFE_DIVIDE(dp.avg_players, dtp.total_avg_players) * dtc.total_cost,
          4
        )                                  AS server_attributed_cost,
        -- 平均接続プレイヤー1人あたりのコスト
        ROUND(
          SAFE_DIVIDE(dtc.total_cost, dtp.total_avg_players),
          4
        )                                  AS cost_per_avg_player
      FROM daily_players dp
      LEFT JOIN daily_total_cost dtc    ON dp.usage_date = dtc.usage_date
      LEFT JOIN daily_total_players dtp ON dp.usage_date = dtp.usage_date
      ORDER BY dp.usage_date DESC, dp.server
    SQL
  }

  labels = merge(local.common_labels, {
    purpose = "minecraft-monitoring"
  })

  depends_on = [google_bigquery_table.server_metrics]
}

# ============================================================
# Outputs
# ============================================================

output "mc_monitoring_dataset_id" {
  description = "Minecraft メトリクス BigQuery データセット ID"
  value       = google_bigquery_dataset.minecraft_monitoring.dataset_id
}

output "mc_monitoring_table_id" {
  description = "Minecraft メトリクス BigQuery テーブル ID"
  value       = google_bigquery_table.server_metrics.table_id
}

output "looker_studio_cost_analysis_url" {
  description = "Looker Studio コスト分析ダッシュボード用データソース接続 URL"
  value       = "https://lookerstudio.google.com/datasources/create?connectorId=bigQuery&projectId=${var.project_id}&datasetId=minecraft_monitoring&tableId=cost_analysis_view"
}

output "mc_monitoring_setup_note" {
  description = "k3s への bq-metrics Deployment デプロイ手順"
  value       = <<-EOT
    BQ メトリクス挿入は k3s Deployment へ移設済み（k8s/onprem/40-bq-metrics.yaml）:
      ssh k3s-worker 'sudo kubectl apply -f /path/to/k8s/onprem/40-bq-metrics.yaml'
      ssh k3s-worker 'sudo kubectl -n minecraft rollout status deploy/bq-metrics'
      ssh k3s-worker 'sudo kubectl -n minecraft logs deploy/bq-metrics --tail=20'
    前提: Secret gcs-backup-credentials が minecraft namespace に存在すること。
  EOT
}
