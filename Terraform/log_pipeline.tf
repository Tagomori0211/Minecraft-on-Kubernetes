# ============================================================
# Minecraft ログイベント駆動パイプライン
# ============================================================
# フロー:
#   k3s mc-log-shipper DaemonSet / survival の log-shipper サイドカー
#   （k8s/onprem/40-mc-log-shipper.yaml / 41-java-log-shipper-cm.yaml）
#     → Pub/Sub mc-raw-logs
#     → Cloud Function (Gen2) → ハッシュ化
#     → Pub/Sub mc-clean-events
#     → BigQuery Subscription (コード不要) → player_activities
#     → Looker Studio
#
# プライバシー設計:
#   XUID + salt (Secret Manager) を SHA256 ハッシュ化し、
#   生 XUID が GCP 上で処理されないようにしている。
#   salt は privacy.tf で定義済みの mc-player-hash-salt を再利用。
# ============================================================

# ============================================================
# API 有効化（Cloud Functions Gen2 に必要な追加 API）
# ============================================================
# pubsub, bigquery, secretmanager は既存のためスキップ

resource "google_project_service" "cloudfunctions" {
  project            = var.project_id
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild" {
  project            = var.project_id
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "eventarc" {
  project            = var.project_id
  service            = "eventarc.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  project            = var.project_id
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

# ============================================================
# Service Accounts
# ============================================================

# Vector DaemonSet 用: mc-raw-logs に publish するだけの最小権限
resource "google_service_account" "mc_log_publisher_sa" {
  account_id   = "mc-log-publisher-sa"
  display_name = "Minecraft Log Publisher SA"
  description  = "Used by Vector DaemonSet on k3s. Publish-only on mc-raw-logs."
}

# Cloud Function 用: salt読取 + raw-logs受信 + clean-events送信
resource "google_service_account" "mc_log_processor_sa" {
  account_id   = "mc-log-processor-sa"
  display_name = "Minecraft Log Processor SA"
  description  = "Used by mc-log-processor Cloud Function. Reads hash salt, publishes clean events."
}

# ============================================================
# Pub/Sub Topic 1: mc-raw-logs（生ログ受信）
# ============================================================

resource "google_pubsub_topic" "mc_raw_logs" {
  project = var.project_id
  name    = "mc-raw-logs"

  labels = merge(local.common_labels, {
    purpose = "minecraft-log-pipeline"
  })

  depends_on = [google_project_service.pubsub]
}

# Vector → mc-raw-logs の publish 権限（SAキー作成禁止ポリシーに備えユーザーにも付与）
resource "google_pubsub_topic_iam_member" "mc_raw_logs_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.mc_raw_logs.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.mc_log_publisher_sa.email}"
}

# フォールバック: ユーザーADCでもpublish可能にする（SAキー作成不可の組織ポリシー対策）
resource "google_pubsub_topic_iam_member" "mc_raw_logs_publisher_user" {
  project = var.project_id
  topic   = google_pubsub_topic.mc_raw_logs.name
  role    = "roles/pubsub.publisher"
  member  = "user:${var.terraform_executor_email}"
}

# Cloud Function → mc-raw-logs の subscriber 権限（Eventarc が自動管理するが明示的に付与）
resource "google_pubsub_topic_iam_member" "mc_raw_logs_subscriber" {
  project = var.project_id
  topic   = google_pubsub_topic.mc_raw_logs.name
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.mc_log_processor_sa.email}"
}

# ============================================================
# Pub/Sub Topic 2: mc-clean-events（ハッシュ化済みイベント）
# ============================================================

resource "google_pubsub_topic" "mc_clean_events" {
  project = var.project_id
  name    = "mc-clean-events"

  labels = merge(local.common_labels, {
    purpose = "minecraft-log-pipeline"
  })

  depends_on = [google_project_service.pubsub]
}

# Cloud Function → mc-clean-events の publish 権限
resource "google_pubsub_topic_iam_member" "mc_clean_events_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.mc_clean_events.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.mc_log_processor_sa.email}"
}

# ============================================================
# Secret Manager 読み取り権限（Cloud Function → mc-player-hash-salt）
# ============================================================

resource "google_secret_manager_secret_iam_member" "mc_log_processor_salt_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.mc_player_hash_salt.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mc_log_processor_sa.email}"
}

# ============================================================
# GCS バケット: Cloud Function ソースコードアップロード用
# ============================================================

resource "google_storage_bucket" "mc_function_source" {
  project                     = var.project_id
  name                        = "${var.project_id}-mc-function-source"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true

  labels = merge(local.common_labels, {
    purpose = "minecraft-log-pipeline"
  })

  depends_on = [google_project_service.cloudfunctions]
}

# Cloud Function ソースコードを zip 化
data "archive_file" "mc_log_processor_source" {
  type        = "zip"
  source_dir  = "${path.module}/cloud_function_source"
  output_path = "${path.module}/cloud_function_source/mc-log-processor.zip"
}

# GCS にアップロード（MD5 ハッシュでバージョニング）
resource "google_storage_bucket_object" "mc_log_processor_archive" {
  name   = "mc-log-processor-${data.archive_file.mc_log_processor_source.output_md5}.zip"
  bucket = google_storage_bucket.mc_function_source.name
  source = data.archive_file.mc_log_processor_source.output_path

  depends_on = [
    google_storage_bucket.mc_function_source,
  ]
}

# ============================================================
# Cloud Function (Gen2): ログ加工・ハッシュ化
# ============================================================

resource "google_cloudfunctions2_function" "mc_log_processor" {
  name        = "mc-log-processor"
  location    = var.region
  description = "Minecraft ログイベント加工: ログイン/ログアウト検出、XUID ハッシュ化、クリーンイベント発行"

  build_config {
    runtime     = "python312"
    entry_point = "process_log_event"

    source {
      storage_source {
        bucket = google_storage_bucket.mc_function_source.name
        object = google_storage_bucket_object.mc_log_processor_archive.name
      }
    }
  }

  service_config {
    max_instance_count    = 1
    min_instance_count    = 0
    available_memory      = "256Mi"
    timeout_seconds       = 60
    service_account_email = google_service_account.mc_log_processor_sa.email
    environment_variables = {
      PROJECT_ID            = var.project_id
      HASH_SALT_SECRET_NAME = google_secret_manager_secret.mc_player_hash_salt.secret_id
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.mc_raw_logs.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  labels = merge(local.common_labels, {
    purpose = "minecraft-log-pipeline"
  })

  depends_on = [
    google_project_service.cloudfunctions,
    google_project_service.cloudbuild,
    google_project_service.eventarc,
    google_project_service.run,
    google_secret_manager_secret_iam_member.mc_log_processor_salt_access,
  ]
}

# Pub/Sub サービスエージェントに Cloud Function 呼び出し権限を付与
# （Eventarc 経由の Pub/Sub → Cloud Functions Gen2 トリガーに必要）
resource "google_cloudfunctions2_function_iam_member" "mc_log_processor_invoker" {
  project        = var.project_id
  location       = var.region
  cloud_function = google_cloudfunctions2_function.mc_log_processor.name
  role           = "roles/cloudfunctions.invoker"
  member         = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Gen2 関数の実体である Cloud Run サービスに run.invoker を付与
# Pub/Sub push サブスクリプションの OIDC トークン（compute デフォルト SA）が
# Cloud Run に認証するために必要。
# ※ cloudfunctions.invoker だけでは Gen2 の Cloud Run レイヤーに反映されないため追加。
resource "google_cloud_run_service_iam_member" "mc_log_processor_run_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.mc_log_processor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

# ============================================================
# BigQuery: player_activities テーブル（既存 minecraft_monitoring データセットに追加）
# ============================================================

resource "google_bigquery_table" "player_activities" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.minecraft_monitoring.dataset_id
  table_id   = "player_activities"

  schema = jsonencode([
    {
      name        = "player_hash"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "SHA256(XUID + salt) — クロスサーバー追跡用の安定したプレイヤー識別子"
    },
    {
      name        = "event_type"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "login または logout"
    },
    {
      name        = "event_timestamp"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "イベント発生時刻（UTC）"
    },
    {
      name        = "server"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "サーバー識別子（survival / lobby / mod / bedrock）"
    },
  ])

  time_partitioning {
    type  = "DAY"
    field = "event_timestamp"
  }

  clustering = ["server", "event_type"]

  labels = merge(local.common_labels, {
    purpose = "minecraft-log-pipeline"
  })

  depends_on = [google_project_service.bigquery]
}

# ============================================================
# BigQuery Subscription: mc-clean-events → BigQuery 自動ストリーミング
# ============================================================
# コード不要。Pub/Sub が直接 BigQuery に書き込む。

resource "google_pubsub_subscription" "mc_clean_events_bq" {
  project = var.project_id
  name    = "mc-clean-events-bq-sub"
  topic   = google_pubsub_topic.mc_clean_events.name

  bigquery_config {
    table               = "${var.project_id}.${google_bigquery_dataset.minecraft_monitoring.dataset_id}.${google_bigquery_table.player_activities.table_id}"
    use_table_schema    = true
    write_metadata      = false
    drop_unknown_fields = true
  }

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"

  labels = merge(local.common_labels, {
    purpose = "minecraft-log-pipeline"
  })

  depends_on = [
    google_bigquery_table.player_activities,
    google_project_service.bigquery,
  ]
}

# Pub/Sub サービスエージェントに BigQuery 書き込み権限を付与
# （BigQuery Subscription の内部メカニズムに必要）
resource "google_bigquery_dataset_iam_member" "pubsub_bq_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.minecraft_monitoring.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
