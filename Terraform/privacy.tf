# ============================================================
# プライバシー設計: プレイヤー XUID ハッシュ化 salt
# ============================================================
# XUID を直接 BQ に保存せず SHA256(XUID + salt) で匿名化する。
# salt は Secret Manager で管理し、Cloud Function mc-log-processor が実行時に取得する。
#
# フロー（log_pipeline.tf）:
#   Pub/Sub mc-raw-logs → mc-log-processor で SHA256(XUID + salt)
#   → player_hash (BQ player_activities) → Looker Studio
#
# ⚠️ salt は tfstate に保存される。tfstate 紛失時は Secret Manager
#    コンソールからバックアップを取ること。
# ============================================================

# Secret Manager API 有効化
resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# 256-bit ランダム salt（terraform state に永続化）
resource "random_id" "mc_player_hash_salt" {
  byte_length = 32
}

resource "google_secret_manager_secret" "mc_player_hash_salt" {
  project   = var.project_id
  secret_id = "mc-player-hash-salt"

  replication {
    auto {}
  }

  labels = merge(local.common_labels, {
    purpose = "minecraft-privacy"
  })

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "mc_player_hash_salt_v1" {
  secret      = google_secret_manager_secret.mc_player_hash_salt.id
  secret_data = random_id.mc_player_hash_salt.hex

  lifecycle {
    # salt を変更すると過去の player_hash が無効化されるため更新禁止
    ignore_changes = [secret_data]
  }
}

# ============================================================
# Outputs
# ============================================================

output "mc_player_hash_salt_secret_name" {
  description = "XUID ハッシュ化 salt の Secret Manager リソース名"
  value       = google_secret_manager_secret.mc_player_hash_salt.name
}
