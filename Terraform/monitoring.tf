# ============================================================
# GCE Monitoring VM (mc-monitoring-1)
# ============================================================
# 構成:
#   - e2-small / asia-northeast1-b (monitoring 専用)
#   - gce/monitoring/compose.yaml を Docker Compose で運用
#     VictoriaMetrics / VictoriaLogs / Vector / Grafana / vmalert /
#     Alertmanager / alertmanager-discord / discord-notifier
#   - vmagent / Vector DaemonSet は k3s-worker 内で動作し Tailscale 経由で送信
#   - Grafana アクセス: Tailscale 経由、または IAP SSH トンネル（外部ポート非公開）
#     gcloud compute ssh mc-monitoring-1 --zone=asia-northeast1-b \
#       --tunnel-through-iap -- -L 3000:localhost:3000
# ⚠️ user-data は gce/monitoring-cloud-init.yaml を file() で埋め込む。
# ============================================================

# ============================================================
# Service Account（最小権限）
# ============================================================

resource "google_service_account" "mc_monitoring_sa" {
  project      = var.project_id
  account_id   = "mc-monitoring-sa"
  display_name = "GCE Monitoring Service Account"
  description  = "mc-monitoring-1 VM 用。Tailscale auth key 取得のための Secret Manager 読取権限のみ。"
}

resource "google_project_iam_member" "mc_monitoring_secret_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.mc_monitoring_sa.email}"
}

# ============================================================
# GCE VM: mc-monitoring-1
# ============================================================

resource "google_compute_instance" "mc_monitoring" {
  project      = var.project_id
  name         = "mc-monitoring-1"
  machine_type = "e2-small"
  zone         = var.zone

  # IAP SSH + Tailscale
  tags = ["minecraft", "tailscale"]

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      # monitoring ワークロードは IOPS 少なめ → pd-standard でコスト削減
      image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.tak_subnet.name
    # Tailscale + package 更新のためエフェメラル外部 IP を付与
    # （外部ポートは IAP SSH のみ開放・Grafana/VM は非公開）
    access_config {}
  }

  service_account {
    email  = google_service_account.mc_monitoring_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data = file("${path.module}/../gce/monitoring-cloud-init.yaml")
  }

  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = merge(local.common_labels, {
    role = "monitoring"
  })

  lifecycle {
    ignore_changes = [metadata["ssh-keys"]]
  }

  depends_on = [google_project_iam_member.mc_monitoring_secret_access]
}

# ============================================================
# Outputs
# ============================================================

output "mc_monitoring_internal_ip" {
  description = "Monitoring VM internal IP（Terraform 確認用）"
  value       = google_compute_instance.mc_monitoring.network_interface[0].network_ip
}

output "mc_monitoring_grafana_tunnel" {
  description = "Grafana アクセス用 IAP SSH トンネルコマンド"
  value       = "gcloud compute ssh mc-monitoring-1 --zone=${var.zone} --tunnel-through-iap -- -L 3000:localhost:3000"
}

output "mc_monitoring_tailscale_ip_check" {
  description = "Tailscale IP 確認コマンド（vmagent remote_write URL 設定に必要）"
  value       = "gcloud compute ssh mc-monitoring-1 --zone=${var.zone} --tunnel-through-iap --command='tailscale ip -4'"
}
