# ============================================================
# Variables
# ============================================================

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "billing_account_id" {
  description = "GCP 請求先アカウント ID（Budget リソース作成に必要）"
  type        = string
}

variable "budget_amount_jpy" {
  description = "月次予算上限 (JPY)。90% / 100% 超過時に Discord アラート通知。"
  type        = number
  default     = 5000
}

variable "terraform_executor_email" {
  description = "Terraform 実行ユーザーの Google アカウントメール（mc-proxy-sa impersonation に必要）"
  type        = string
  default     = "tagomoriyuukichi@gmail.com"
}

variable "region" {
  description = "GCP リージョン"
  type        = string
  default     = "asia-northeast1" # 東京リージョン
}

variable "zone" {
  description = "GCP ゾーン（mc-proxy MIG / mc-monitoring-1 の配置先）"
  type        = string
  default     = "asia-northeast1-b"
}

variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
  default     = "prod"
}

# ============================================================
# Network Variables
# ============================================================
variable "vpc_name" {
  description = "VPC network name"
  type        = string
  default     = "tak-vpc"
}

variable "subnet_cidr" {
  description = "Subnet CIDR（GCE VM 用）"
  type        = string
  default     = "10.100.0.0/20" # 4096 IPs
}

# ============================================================
# Proxmox Variables（オンプレ VM管理）
# ============================================================
variable "proxmox_api_url" {
  description = "Proxmox API URL (例: https://192.168.0.xxx:8006/api2/json)"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API Token ID (書式: user@pam!tokenid)"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API Token Secret"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "VM接続用SSHパブリックキー"
  type        = string
}

variable "vms" {
  description = "Proxmox VM構成マップ"
  type = map(object({
    vmid        = number
    desc        = string
    cores       = number
    memory      = number
    ip          = string
    disk_size   = string
    target_node = string
    template_id = string
  }))
  default = {}
}

variable "common_config" {
  description = "VM共通設定"
  type = object({
    gateway     = string
    template_id = number
    target_node = string
  })
}

variable "proxmox_cipassword" {
  description = "Proxmox cloud-init password"
  type        = string
  sensitive   = true
  default     = ""
}

