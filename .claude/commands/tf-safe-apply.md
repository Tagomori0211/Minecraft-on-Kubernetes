---
description: Safe Terraform Apply（plan 確認 → 破壊的変更強調 → 承認後 apply）
---

# Safe Terraform Apply

1. `Terraform/` で `terraform plan -var-file=secret.tfvars -out=tfplan` を実行し、出力全体を表示する
2. リソースの REPLACEMENT または DESTROY アクションを強調表示する
3. 特に以下をチェックする
   - `google_compute_instance_template.mc_proxy` の replace（= MIG が入口 VM を再作成し数分ダウン。`gce/cloud-init.yaml` を変更すると必ず発生）
   - `google_compute_address.minecraft_ip` の replace（公開 IP 35.200.78.252 が変わる。絶対に避ける）
   - Proxmox VM の `vm_state`（停止中 VM の起動）・タグ・ブートデバイス問題
4. `terraform apply tfplan` の前に明示的なユーザー確認を待つ
5. apply 後、もう一度 `terraform plan -var-file=secret.tfvars` を実行してクリーンな状態を確認し、`tfplan` ファイルを削除する（機密値を含むためコミット禁止）
