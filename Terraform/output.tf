# ============================================================
# Outputs
# ============================================================

# ネットワーク情報
output "vpc_name" {
  description = "VPC network name"
  value       = google_compute_network.tak_vpc.name
}

output "subnet_name" {
  description = "Subnet name"
  value       = google_compute_subnetwork.tak_subnet.name
}

# 静的IP
output "minecraft_static_ip" {
  description = "Minecraft 公開エンドポイントの静的IP（mc-gateway に付与）"
  value       = google_compute_address.minecraft_ip.address
}

# Tailscale設定用情報
output "tailscale_firewall_rule" {
  description = "Tailscale firewall rule name"
  value       = google_compute_firewall.tailscale_udp.name
}

# ============================================================
# ログパイプライン Outputs
# ============================================================

output "mc_log_pipeline_pubsub_topics" {
  description = "Pub/Sub topic names for the log pipeline"
  value = {
    raw_logs     = google_pubsub_topic.mc_raw_logs.name
    clean_events = google_pubsub_topic.mc_clean_events.name
  }
}

output "mc_log_publisher_sa_key_setup" {
  description = "Vector SA キーを作成し k8s Secret に保存する手順"
  value       = <<-EOT
    # mc-log-publisher-sa のキーを作成:
    gcloud iam service-accounts keys create vector-key.json \
      --iam-account=mc-log-publisher-sa@${var.project_id}.iam.gserviceaccount.com \
      --project=${var.project_id}

    # k3s ノードにキーを転送:
    scp vector-key.json k3s-worker:~/

    # k3s ノードで Secret を作成（kubectl は実機で実行する必要あり）:
    ssh k3s-worker "kubectl create secret generic vector-gcp-credentials \
      -n minecraft \
      --from-file=key.json=./vector-key.json \
      --from-literal=project-id=${var.project_id}"

    # Vector DaemonSet をデプロイ:
    ssh k3s-worker "kubectl apply -f ~/k8s_manifests/40-vector-daemonset.yaml"

    # 動作確認:
    ssh k3s-worker "kubectl logs -n minecraft -l app.kubernetes.io/name=vector --tail=20"
  EOT
}

output "mc_player_activities_table" {
  description = "BigQuery player_activities テーブル ID"
  value       = google_bigquery_table.player_activities.table_id
}

output "mc_log_processor_function_name" {
  description = "Cloud Function (Gen2) 名"
  value       = google_cloudfunctions2_function.mc_log_processor.name
}
