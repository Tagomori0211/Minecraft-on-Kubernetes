# ============================================================
# GCE: mc-gateway（入口 socat・監視スタック・Status Platform を集約した単体 VM）
# ============================================================
# 2026-09 に mc-proxy（MIG）/ mc-monitoring-1 / tagomori-app の 3 台を 1 台に統合する。
#
# 構成（詳細は gce/gateway/ と gce/README.md）:
#   - systemd: socat（Java 25565/tcp・Bedrock 19132/udp → Tailscale → k3s-worker）、課金通知、node-exporter
#   - docker compose: VictoriaMetrics / VictoriaLogs / Grafana / vmalert / Alertmanager
#   - Status Platform（cloud-observability-gateway の CI が OS Login で ~/app に配置）
#   - 単体 VM のためブートディスク（監視データ・MariaDB・Tailscale ノード状態）は再起動後も保持される
#
# 公開 IP の切替手順（var.gateway_use_static_ip）:
#   false: 一時 IP で構築・検証（旧 mc-proxy MIG が 35.200.78.252 を保持中）
#   true : MIG 削除で 35.200.78.252 を解放した後に付け替える（入口の停止は付け替えの数分のみ）
# ============================================================

resource "google_compute_instance" "mc_gateway" {
  name         = "mc-gateway"
  machine_type = var.gateway_machine_type
  zone         = var.zone

  # minecraft: 25565/tcp・19132/udp・IAP SSH、tailscale: 41641/udp
  tags = ["minecraft", "tailscale"]

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.tak_subnet.name
    access_config {
      nat_ip = var.gateway_use_static_ip ? google_compute_address.minecraft_ip.address : null
    }
  }

  # tagomori-app と同じ SA（Secret Manager 読取・BigQuery・GCS・Pub/Sub の既存権限、CI の actAs 付与済み）
  service_account {
    email  = google_service_account.mc_proxy_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data = file("${path.module}/../gce/gateway/cloud-init.yaml")
    # Status Platform の CI SA が OS Login + IAP で SSH デプロイする
    enable-oslogin = "TRUE"
  }

  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = merge(local.common_labels, {
    role = "gateway"
  })

  depends_on = [
    google_project_iam_member.mc_proxy_secret_access,
    google_pubsub_subscription_iam_member.mc_gateway_billing_subscriber,
  ]
}

output "mc_gateway_external_ip" {
  description = "mc-gateway の外部 IP（gateway_use_static_ip=true で 35.200.78.252）"
  value       = google_compute_instance.mc_gateway.network_interface[0].access_config[0].nat_ip
}
