# Bedrock サーバー メンテナンス再起動

バックアップ CronJob（`gcs-backup-cronjob` / `gcs-daily-backup-cronjob`）と同じアナウンスシーケンスで Bedrock サーバーを再起動する。
必ずアナウンス → グレースフルストップ → replicas=0 → replicas=1 の順で実行すること。

## 手順

以下をすべて順番に実行する（並列実行・省略禁止）。

### 1. 現在の Pod 名を取得

```bash
ssh k3s-worker 'sudo kubectl -n minecraft get pods -l app=mc-bedrock --no-headers -o custom-columns=":metadata.name"'
```

### 2. アナウンスシーケンス（リモートで一括実行）

`<POD_NAME>` を手順1で取得した値に置換して実行する。

```bash
ssh k3s-worker 'sudo kubectl -n minecraft exec <POD_NAME> -c bedrock -- send-command "say [メンテナンス] サーバーを再起動します" && sleep 5 && sudo kubectl -n minecraft exec <POD_NAME> -c bedrock -- send-command "say 30秒後にサーバーは再起動します" && sleep 25 && sudo kubectl -n minecraft exec <POD_NAME> -c bedrock -- send-command "say 再起動します" && sleep 5 && sudo kubectl -n minecraft exec <POD_NAME> -c bedrock -- send-command stop'
```

### 3. スケールダウン（replicas=0）

```bash
ssh k3s-worker 'sudo kubectl scale deployment deploy-bedrock -n minecraft --replicas=0'
```

### 4. Pod 完全終了を待機

```bash
ssh k3s-worker 'sudo kubectl -n minecraft wait --for=delete pod/<POD_NAME> --timeout=60s'
```

### 5. スケールアップ（replicas=1）

```bash
ssh k3s-worker 'sudo kubectl scale deployment deploy-bedrock -n minecraft --replicas=1'
```

### 6. 起動完了を確認

```bash
ssh k3s-worker 'sudo kubectl -n minecraft rollout status deployment/deploy-bedrock'
```

## 注意事項

- `rollout restart` は使用禁止（旧 Pod と新 Pod が並走しアドオン変更が反映されない場合がある）
- replicas=0 で完全停止してから replicas=1 にすること
- アナウンスを省略しないこと（プレイヤーが接続中の可能性がある）
