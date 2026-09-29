# ============================================================
# GCP設定
# ============================================================
# GCPプロジェクトID（gcloud projects list で確認）
project_id         = "project-61cf5742-d0ea-45ed-ac0"
billing_account_id = "01D081-BB268A-137D65"

# 月次予算上限（JPY）: monitoring VM 追加後の想定上限
budget_amount_jpy = 8000

# ============================================================
# オンプレ設定（Proxmox）
# ============================================================
# 共通設定
common_config = {
  gateway     = "192.168.0.1"
  template_id = 9000        # 用意済みのテンプレートID
  target_node = "mc-server" # ※環境に合わせて変更してください（例: pve1, proxmoxなど）
}

# VMリスト
# オンプレは k3s-worker のみ（監視は GCE で完結）。
# 旧 k3s-monitoring（s3 ホスト, vmid 100）は 2026-09-30 に削除対象とした。
vms = {
  # シングルノード: オンプレ：k3s-worker (Java/Bedrock マイクラゲームサーバー用 + Status Platform)
  k3s-worker = {
    vmid        = 105
    desc        = "Single K3s Node for all services (Minecraft + Infrastructure)"
    cores       = 16
    memory      = 59392
    ip          = "192.168.0.151"
    disk_size   = "200G"
    target_node = "mc-server"
    template_id = "ubuntu-2404-cloud-init"
  }
}
