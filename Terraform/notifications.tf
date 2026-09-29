# ============================================================
# Discord 通知統合
# ============================================================
# 1. Billing Budget (90%/100%) → Pub/Sub → GCE VM Pull → Discord
#    （Cloud Functions は Cloudflare に ASN ブロックされるため GCE VM 経由に変更）
# 2. バックアップ CronJob → gcloud storage sign-url → Discord
#    (signed URL 生成用に Terraform 実行ユーザーに serviceAccountTokenCreator を付与)
# ============================================================

# ============================================================
# API 有効化
# ============================================================

resource "google_project_service" "pubsub" {
  project            = var.project_id
  service            = "pubsub.googleapis.com"
  disable_on_destroy = false
}

# ============================================================
# Discord webhook URL (Secret Manager)
# ============================================================
# ⚠️ secret_data は Terraform 管理外。apply 後に手動で設定:
#   echo -n "https://discord.com/api/webhooks/..." | \
#     gcloud secrets versions add mc-discord-webhook-url --data-file=-

resource "google_secret_manager_secret" "discord_webhook_url" {
  project   = var.project_id
  secret_id = "mc-discord-webhook-url"

  replication {
    auto {}
  }

  labels = merge(local.common_labels, {
    purpose = "discord-notification"
  })

  depends_on = [google_project_service.secretmanager]
}

# mc-proxy-sa に discord_webhook_url の読み取り権限を付与
# （backup CronJob が署名付き URL 通知に使用する）
resource "google_secret_manager_secret_iam_member" "mc_proxy_webhook_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.discord_webhook_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mc_proxy_sa.email}"
}

# mc-monitoring-sa に webhook 読み取り権限を付与
# （監視系再構築で discord-notifier を mc-monitoring-1 へ移設したため）
resource "google_secret_manager_secret_iam_member" "mc_monitoring_webhook_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.discord_webhook_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mc_monitoring_sa.email}"
}

# ============================================================
# Pub/Sub topic
# ============================================================

resource "google_pubsub_topic" "billing_alerts" {
  project = var.project_id
  name    = "billing-alerts"

  labels = merge(local.common_labels, {
    purpose = "billing-notification"
  })

  depends_on = [google_project_service.pubsub]
}

# ============================================================
# Pub/Sub Pull サブスクリプション（GCE VM が 5 分ごとにポーリング）
# ============================================================

resource "google_pubsub_subscription" "billing_alerts_gce" {
  project = var.project_id
  name    = "billing-alerts-gce-pull"
  topic   = google_pubsub_topic.billing_alerts.name

  # 未確認メッセージを 7 日間保持
  message_retention_duration = "604800s"
  retain_acked_messages      = false

  # Ack 期限: スクリプト実行時間 (最大 60 秒) + バッファ
  ack_deadline_seconds = 120

  labels = merge(local.common_labels, {
    purpose = "billing-notification"
  })
}

# mc-monitoring-sa に Pull サブスクリプション Subscriber 権限を付与
# （discord-notifier が mc-monitoring-1 で課金アラートを pull する）
resource "google_pubsub_subscription_iam_member" "mc_monitoring_billing_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.billing_alerts_gce.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.mc_monitoring_sa.email}"
}

# mc-gateway（SA: mc-proxy-sa）の課金通知 mc-discord-notifier が pull する
resource "google_pubsub_subscription_iam_member" "mc_gateway_billing_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.billing_alerts_gce.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.mc_proxy_sa.email}"
}

# NOTE: オンプレ沈黙検知は vmalert(OnpremSilence) + Alertmanager へ移行したため
#       mc-monitoring-sa の Pub/Sub publisher 付与は廃止（discord-notifier は
#       課金アラートの subscriber のみ必要）。

# ============================================================
# Billing Budget (90% + 100%)
# ============================================================

resource "google_billing_budget" "mc_budget" {
  provider        = google-beta.billing
  billing_account = var.billing_account_id
  display_name    = "Minecraft Infrastructure Budget"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = "JPY"
      units         = tostring(var.budget_amount_jpy)
    }
  }

  # 90% 超過アラート
  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  # 100% 超過アラート
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  all_updates_rule {
    pubsub_topic = google_pubsub_topic.billing_alerts.id
  }
}

# ============================================================
# signed URL 署名権限（バックアップ CronJob 用）
# ============================================================
# gcs-backup-cronjob の backup.sh が
#   gcloud storage sign-url --impersonate-service-account mc-proxy-sa
# を実行できるよう、Terraform 実行ユーザーに serviceAccountTokenCreator を付与する。

resource "google_service_account_iam_member" "user_impersonate_mc_proxy_sa" {
  service_account_id = google_service_account.mc_proxy_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.terraform_executor_email}"
}

# ============================================================
# Outputs
# ============================================================

output "discord_webhook_secret_setup" {
  description = "Discord webhook URL を Secret Manager に設定するコマンド"
  value       = <<-EOT
    Discord webhook URL を設定してください:
      echo -n "https://discord.com/api/webhooks/<ID>/<TOKEN>" | \
        gcloud secrets versions add mc-discord-webhook-url --data-file=-
  EOT
}

output "billing_budget_display_name" {
  description = "作成した Budget の表示名"
  value       = google_billing_budget.mc_budget.display_name
}

output "billing_alerts_subscription" {
  description = "GCE VM が Pull するサブスクリプション名"
  value       = google_pubsub_subscription.billing_alerts_gce.name
}
