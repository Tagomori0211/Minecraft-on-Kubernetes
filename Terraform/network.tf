# ============================================================
# Network: VPC / Subnet / Firewall / 静的IP
# ============================================================
# GCE（mc-proxy MIG / mc-monitoring-1）が共用するネットワーク基盤。
# ============================================================

# ============================================================
# VPC Network
# ============================================================
resource "google_compute_network" "tak_vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "tak_subnet" {
  name          = "${var.vpc_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.tak_vpc.id

  # セカンダリレンジは使用しない。true でないと、定義を省いても API 上の
  # 既存レンジが残り続ける（provider が API 値を既定値として扱うため）。
  send_secondary_ip_range_if_empty = true

  private_ip_google_access = true
}

# ============================================================
# Firewall Rules
# ============================================================

# Tailscale UDP 通信用
resource "google_compute_firewall" "tailscale_udp" {
  name    = "${var.vpc_name}-allow-tailscale"
  network = google_compute_network.tak_vpc.name

  allow {
    protocol = "udp"
    ports    = [tostring(local.tailscale_port)]
  }

  # Tailscale は基本的にどこからでも接続可能にする
  # (実際の認証は Tailscale 側で行われる)
  source_ranges = ["0.0.0.0/0"]

  target_tags = ["tailscale"]

  description = "Allow Tailscale UDP traffic for VPN"
}

# Minecraft 用（mc-proxy の socat が 25565/TCP・19132/UDP で待受）
# MIG オートヒーリングの TCP:25565 ヘルスチェックもこのルールで到達する（gce.tf 参照）
resource "google_compute_firewall" "minecraft_tcp" {
  name    = "${var.vpc_name}-allow-minecraft"
  network = google_compute_network.tak_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["25565"]
  }

  allow {
    protocol = "udp"
    ports    = ["19132"]
  }

  source_ranges = ["0.0.0.0/0"]

  target_tags = ["minecraft"]

  description = "Allow Minecraft TCP/UDP traffic"
}

# VPC 内部通信用
resource "google_compute_firewall" "internal" {
  name    = "${var.vpc_name}-allow-internal"
  network = google_compute_network.tak_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]

  description = "Allow internal communication within VPC"
}

# ============================================================
# 静的IP（Minecraft 公開エンドポイント 35.200.78.252）
# ============================================================
# mc-proxy MIG のインスタンステンプレート access_config.nat_ip で付与する（gce.tf）。
# ⚠️ google_compute_address は description を含む属性変更が再作成（= 公開IPが変わる）に
#    なるため、description の文言が古くても変更しないこと。

resource "google_compute_address" "minecraft_ip" {
  name        = "tagomori-minecraft-ip"
  region      = var.region
  description = "Static IP for Minecraft Velocity Proxy"
}
