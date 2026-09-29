---
description: リポジトリ棚卸し（ドキュメント・マニフェスト・実環境の乖離と不要物を読み取り専用で洗い出す）
---

# リポジトリ棚卸し（repo-audit）

## 目的
構成変更の積み重ねで生じる「ドキュメント／マニフェストと実環境の乖離」「使われていないファイル・クラスタ上の孤児リソース」「壊れたジョブ」を、**読み取り専用**で洗い出して報告する。

## 対象
- リポジトリ: `/home/shinari/MC_k3s`（`k8s/onprem/`・`gce/`・`Terraform/`・`Ansible/`・`.agents/`・`.clinerules/`・`.claude/`・`Documents/`・`README.md`）
- k3s: `k3s-worker`（`minecraft` / `monitoring-prometheus` namespace）
- GCP: GCE インスタンス・Terraform state

## 事前条件
- `git -C /home/shinari/MC_k3s fetch origin` 済みで、ローカルが origin/main と一致していること（別 clone で更新されている場合があるため）
- kubectl / helm / gcloud は SSH 経由（`.agents/workflows/k3s-ssh-operations.md`）

## 手順（すべて読み取り専用。削除・apply・scale はしない）

### 1. リポジトリの同期確認
```bash
git -C /home/shinari/MC_k3s status -sb
```

### 2. クラスタの実態とマニフェストの突き合わせ
```bash
ssh k3s-worker 'sudo kubectl get deploy,ds,sts,cronjob -A -o wide'
```
```bash
ssh k3s-worker 'helm list -A && sudo kubectl get cm,secret,sa,pvc -n minecraft && sudo kubectl get cm,sa -n monitoring-prometheus'
```
- マニフェストに無いのにクラスタにあるもの（孤児）、マニフェストにあるのに無いもの（未適用・死蔵）を列挙する
- `helm get manifest <release> -n minecraft` で、release が管理する実体が残っているか確認する
- `homepage` / `misskey` / `relay` / `minecraft-data` namespace は本リポジトリ管理外なので対象外

### 3. ジョブの健全性
```bash
ssh k3s-worker 'sudo kubectl get jobs -n minecraft --sort-by=.metadata.creationTimestamp'
```
- 失敗が続く CronJob は原因（配布 URL の消失など）を推定して報告する。**手動実行はしない**（アナウンス・サーバー停止を伴うため）

### 4. GCE と Terraform
```bash
ssh k3s-worker 'gcloud compute instances list'
```
```bash
terraform -chdir=/home/shinari/MC_k3s/Terraform plan -var-file=secret.tfvars -no-color
```
- plan の差分を「今回の変更」と「以前からの未適用ドリフト」に分けて報告する（replace / destroy は強調）

### 5. ドキュメントの乖離
```bash
ssh k3s-worker 'tailscale status'
```
```bash
grep -rn --exclude-dir=.git --exclude-dir=DocMd --exclude-dir=Task_mds --exclude-dir=ModList --exclude-dir=.terraform --exclude-dir=OperationPostmortem -e "<撤去済みの名前>" /home/shinari/MC_k3s
```
- 撤去済みコンポーネント名・固定 IP・存在しないパスやコマンドが残っていないか確認する
- `Documents/OperationPostmortem/` は当時の記録なので対象外

### 6. 報告
以下の表で報告し、対応はユーザーの確認後に行う。

| 区分 | 対象 | 根拠（確認コマンドの結果） | 提案 | リスク |
|------|------|--------------------------|------|--------|
| 不要ファイル / 孤児リソース / ドリフト / 壊れたジョブ / 記載の乖離 | | | | |

## 触ってはいけないもの
- `gce/` 配下のパス: GCE の cloud-init が起動時に main から clone して参照する
- `gce/*cloud-init.yaml`: 変更すると VM 再作成（入口ダウン）を伴う
- `google_compute_address.minecraft_ip`: 属性変更で公開 IP 35.200.78.252 が変わる
- PVC（ワールドデータ）: 削除すると復元できない

## 参照
- `.agents/workflows/k3s-ssh-operations.md`
- `.claude/commands/tf-safe-apply.md`
- `.claude/commands/command-recommender.md`
