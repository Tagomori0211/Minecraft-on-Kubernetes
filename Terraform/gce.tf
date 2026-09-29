# ============================================================
# GCE Minecraft Proxy (mc-proxy)
# ============================================================
# 公開エンドポイント。自宅 IP を隠蔽し、socat-tcp / socat-bedrock（Docker Compose）で
# Tailscale 経由のオンプレ k3s へ透過転送する（gce/compose.yaml）。
#
# 構成:
#   - e2-micro / asia-northeast1-b / Ubuntu 24.04 LTS / pd-balanced 20GB
#   - 静的IP 35.200.78.252（tagomori-minecraft-ip）をテンプレートの access_config にアタッチ
#   - cloud-init で Docker / Tailscale / mc-proxy.service をプロビジョニング
#   - Service Account `mc-proxy-sa` に Secret Manager 読取権限のみ付与
#
# 参照リソース（network.tf）:
#   - VPC: google_compute_network.tak_vpc
#   - Subnet: google_compute_subnetwork.tak_subnet
#   - Firewall: tailscale_udp / minecraft_tcp（target_tags で適用）
#   - 静的IP: google_compute_address.minecraft_ip
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

  description = "Allow SSH via IAP for mc-proxy-1 management"
}

# ============================================================
# Service Account（最小権限）
# ============================================================
resource "google_service_account" "mc_proxy_sa" {
  account_id   = "mc-proxy-sa"
  display_name = "GCE Minecraft Proxy Service Account"
  description  = "Used by mc-proxy-1 VM. Allows reading Secret Manager values only."
}

resource "google_project_iam_member" "mc_proxy_secret_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.mc_proxy_sa.email}"
}

# ============================================================
# GCE: mc-proxy インスタンステンプレート + オートヒーリング MIG
# ============================================================
# 単体 VM を Managed Instance Group (zonal, size=1) 化し、
# TCP:25565 ヘルスチェックで自動復旧（autohealing）を有効化する。
# 静的IP 35.200.78.252 はテンプレートの access_config.nat_ip で付与する。
#
# ⚠️ インスタンス名は mc-proxy-xxxx（動的）。旧単体 VM 名 `mc-proxy-1` は存在しない。
#    SSH 時は `gcloud compute instances list --filter="name~^mc-proxy-"` で現行名を取得する。
# ⚠️ user-data は gce/cloud-init.yaml を file() で埋め込むため、同ファイルを
#    1 文字でも変更するとテンプレート再作成 → MIG の REPLACE（入口ダウンタイム）になる。
#    cloud-init は起動時に main ブランチの gce/ を clone して配置する点にも注意。
# ============================================================

resource "google_compute_instance_template" "mc_proxy" {
  name_prefix = "mc-proxy-"
  # socat-tcp/socat-bedrock の薄いプロキシのみ稼働するため e2-micro。
  machine_type = "e2-micro"
  tags         = ["minecraft", "tailscale"]

  disk {
    source_image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
    disk_size_gb = 20
    disk_type    = "pd-balanced"
    boot         = true
    auto_delete  = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.tak_subnet.name
    access_config {
      nat_ip = google_compute_address.minecraft_ip.address
    }
  }

  service_account {
    email  = google_service_account.mc_proxy_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data = file("${path.module}/../gce/cloud-init.yaml")
  }

  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = local.common_labels

  # テンプレート差し替え時に新テンプレートを先に作成
  lifecycle {
    create_before_destroy = true
  }
}

# autohealing 用 TCP ヘルスチェック（socat が 25565 を LISTEN していれば healthy）
# GCP ヘルスチェッカ (35.191.0.0/16 / 130.211.0.0/22) は既存 minecraft_tcp
# (0.0.0.0/0 → 25565) で到達可能なため追加 FW 不要。
resource "google_compute_health_check" "mc_proxy_tcp" {
  name                = "mc-proxy-25565-hc"
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = 25565
  }

  log_config {
    enable = true
  }
}

resource "google_compute_instance_group_manager" "mc_proxy" {
  name               = "mc-proxy-mig"
  base_instance_name = "mc-proxy"
  zone               = var.zone
  target_size        = 1

  version {
    instance_template = google_compute_instance_template.mc_proxy.id
  }

  named_port {
    name = "minecraft"
    port = 25565
  }

  auto_healing_policies {
    health_check = google_compute_health_check.mc_proxy_tcp.id
    # cloud-init + Docker + Tailscale + socat 起動の猶予（誤検知での kill ループ防止）
    initial_delay_sec = 300
  }

  # 静的IP 35.200.78.252 はテンプレートの access_config.nat_ip で付与する。
  # （stateful_external_ip を併用すると初回作成時に nat_ip が無視され ephemeral
  #   が割り当たる不具合があったため不使用。size=1 のため autoheal の
  #   delete→create で予約IPは解放後に再アタッチされる。）
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
  }

  depends_on = [
    google_project_iam_member.mc_proxy_secret_access,
  ]
}

# ============================================================
# Outputs
# ============================================================
output "mc_proxy_external_ip" {
  description = "GCE Minecraft Proxy 静的外部IP（MIG テンプレートの nat_ip で付与）"
  value       = google_compute_address.minecraft_ip.address
}

output "mc_proxy_mig" {
  description = "mc-proxy Managed Instance Group 名"
  value       = google_compute_instance_group_manager.mc_proxy.name
}
