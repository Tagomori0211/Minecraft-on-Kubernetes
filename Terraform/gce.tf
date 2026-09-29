# ============================================================
# GCE 共通: IAP SSH ファイアウォール・VM 用 Service Account
# ============================================================
# VM 本体は gateway.tf（mc-gateway）。ネットワーク・静的 IP は network.tf。
# ============================================================

# ============================================================
# Firewall: IAP SSH
# ============================================================
# GCP IAP (Identity-Aware Proxy) からの SSH を許可
# IAP のソース IP レンジは 35.235.240.0/20
resource "google_compute_firewall" "iap_ssh" {
  name    = "${var.vpc_name}-allow-iap-ssh"
  network = google_compute_network.tak_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["minecraft"]

  description = "Allow SSH via IAP for mc-gateway management"
}

# ============================================================
# Service Account（mc-gateway の VM SA）
# ============================================================
resource "google_service_account" "mc_proxy_sa" {
  account_id   = "mc-proxy-sa"
  display_name = "GCE Minecraft Proxy Service Account"
  description  = "Service account of the mc-gateway VM (ingress, monitoring and Status Platform)."
}

resource "google_project_iam_member" "mc_proxy_secret_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.mc_proxy_sa.email}"
}
