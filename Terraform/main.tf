# ============================================================
# TAK Pipeline - Hybrid Cloud Minecraft Infrastructure
# ============================================================
# GCP（入口 mc-proxy MIG / 監視 mc-monitoring-1 / BigQuery / Pub/Sub /
# Secret Manager / Budget）とオンプレ Proxmox VM を管理する。
#
# ファイル構成:
#   network.tf              VPC / Subnet / Firewall / 静的IP
#   gce.tf                  mc-proxy インスタンステンプレート + オートヒーリング MIG
#   monitoring.tf           mc-monitoring-1 VM
#   minecraft_monitoring.tf BigQuery メトリクス / コスト分析 VIEW
#   log_pipeline.tf         ログイベント Pub/Sub + Cloud Function (Gen2)
#   notifications.tf        課金 Budget → Pub/Sub → Discord
#   billing.tf / privacy.tf / gcs_backup.tf / proxmox.tf
# ============================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc04"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # State管理（本番運用時はGCSバックエンドを推奨）
  # backend "gcs" {
  #   bucket = "tak-pipeline-tfstate"
  #   prefix = "minecraft-infra"
  # }
}

# ============================================================
# Provider Configuration
# ============================================================
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# billingbudgets.googleapis.com は ADC の quota project 明示が必要なため専用エイリアスを使用
# billing_project: ADC ユーザー認証情報で quota project を強制する
provider "google-beta" {
  alias                 = "billing"
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

# ============================================================
# Data Sources
# ============================================================
data "google_project" "current" {
  project_id = var.project_id
}

# ============================================================
# Local Values
# ============================================================
locals {
  # 共通ラベル
  common_labels = {
    "app-part-of" = "tak-pipeline"
    "environment" = var.environment
    "managed-by"  = "terraform"
  }

  # Tailscale UDP port
  tailscale_port = 41641
}
