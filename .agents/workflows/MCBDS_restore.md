---
description: Restore Bedrock World from mcworld backup
---

このワークフローは、Bedrock Dedicated Server (BDS) のワールドデータを `.mcworld` バックアップからリストアします。

**前提:**
- kubectl はすべて `ssh k3s-worker 'sudo kubectl ...'` 経由で実行する（クライアントから直接実行不可）
- リストアする `.mcworld` ファイルがカレントディレクトリにあること（以下の例: `backup.mcworld`）
- BDS Deployment: `deploy-bedrock` / Namespace: `minecraft` / PVC: `pvc-bedrock`
- ワールド名は `sushi_server`（`k8s/onprem/backend-servers.yaml` の `LEVEL_NAME` と同じ）。
  展開先ディレクトリ `/data/worlds/sushi_server` と LEVEL_NAME は必ず一致させる

---

## 1. BDS 停止

プレイヤーが接続中の可能性がある場合は、先に `.claude/commands/bedrock-restart.md` の手順 2（アナウンス）を実施する。

```bash
ssh k3s-worker 'sudo kubectl scale deploy/deploy-bedrock -n minecraft --replicas=0'
```

Pod が完全に停止するまで待ちます。

```bash
ssh k3s-worker 'sudo kubectl wait --for=delete pod -l app=mc-bedrock -n minecraft --timeout=120s'
```

---

## 2. 作業用 Pod (Helper) の起動

以下を `bedrock-restore-helper.yaml` として保存します。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bedrock-restore-helper
  namespace: minecraft
  labels:
    app.kubernetes.io/name: bedrock-restore-helper
    app.kubernetes.io/component: maintenance
    app.kubernetes.io/managed-by: kubectl
    env: prod
spec:
  restartPolicy: Never
  containers:
    - name: restore-helper
      image: alpine:3.20
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: pvc-bedrock
```

```bash
scp bedrock-restore-helper.yaml k3s-worker:/tmp/bedrock-restore-helper.yaml
```

```bash
ssh k3s-worker 'sudo kubectl apply -f /tmp/bedrock-restore-helper.yaml && sudo kubectl wait pod/bedrock-restore-helper -n minecraft --for=condition=Ready --timeout=60s'
```

---

## 3. ツールインストールと既存データの退避

```bash
ssh k3s-worker 'sudo kubectl exec bedrock-restore-helper -n minecraft -- sh -c "apk add --no-cache unzip && cd /data/worlds && if [ -d sushi_server ]; then mv sushi_server sushi_server.$(date +%Y%m%d_%H%M%S).bak && echo Existing world backed up; fi"'
```

---

## 4. バックアップファイルのコピー

```bash
scp backup.mcworld k3s-worker:/tmp/backup.mcworld
```

```bash
ssh k3s-worker 'sudo kubectl cp /tmp/backup.mcworld minecraft/bedrock-restore-helper:/data/backup.mcworld'
```

---

## 5. ワールドの展開とリストア

```bash
ssh k3s-worker 'sudo kubectl exec bedrock-restore-helper -n minecraft -- sh -c "mkdir -p /data/worlds/sushi_server && cd /data/worlds/sushi_server && unzip -o /data/backup.mcworld && ( [ -f world_behavior_packs.json ] || echo \"[]\" > world_behavior_packs.json ) && ( [ -f world_resource_packs.json ] || echo \"[]\" > world_resource_packs.json ) && chown -R 1000:1000 /data && echo Done"'
```

**注意:** `world_resource_packs.json` は VV（Vibrant Visuals）との互換性のため `[]` を維持すること。リソースパックはクライアント側グローバルリソースパックとして適用すること。

**注意:** `.mcworld` 由来の level.dat が `LANBroadcast=0` だと MOTD が欠落し接続不能になる（`Documents/OperationPostmortem/postmortem-bedrock-motd-unjoinable.md`）。起動後に vmalert `BedrockUnjoinableNoMOTD` が発火しないことを確認する。

---

## 6. クリーンアップと Pod 削除

```bash
ssh k3s-worker 'sudo kubectl exec bedrock-restore-helper -n minecraft -- rm -f /data/backup.mcworld'
```

```bash
ssh k3s-worker 'sudo kubectl delete pod bedrock-restore-helper -n minecraft --force && rm -f /tmp/backup.mcworld /tmp/bedrock-restore-helper.yaml'
```

---

## 7. BDS 起動と確認

BDS 再起動は rollout restart 禁止。replicas=0 → 1 の順で行います。

```bash
ssh k3s-worker 'sudo kubectl scale deploy/deploy-bedrock -n minecraft --replicas=1'
```

```bash
ssh k3s-worker 'sudo kubectl rollout status deploy/deploy-bedrock -n minecraft'
```

---

## 8. 起動ログの確認

```bash
ssh k3s-worker 'sudo kubectl logs deploy/deploy-bedrock -c bedrock -n minecraft --tail=30'
```

確認項目:
- `Level Name: sushi_server` が表示されること
- `Server started.` が表示されること
- エラーやクラッシュがないこと

---

## ロールバック手順（リストアに失敗した場合）

手順 1（BDS 停止）→ 手順 2（Helper 起動）を再実施したうえで、最新の退避ディレクトリを戻します。
退避ディレクトリが見つからない場合は何も削除せずに終了します（`[ -n "$LATEST" ]` ガード）。

```bash
ssh k3s-worker 'sudo kubectl exec bedrock-restore-helper -n minecraft -- sh -c "cd /data/worlds && LATEST=\$(ls -d sushi_server.*.bak 2>/dev/null | sort | tail -1) && [ -n \"\$LATEST\" ] && rm -rf sushi_server && mv \"\$LATEST\" sushi_server && echo Rollback done: \$LATEST"'
```

その後、手順 6（Helper 削除）→ 手順 7（BDS 起動）を実施します。

---

## 注意事項

- `VERSION=LATEST` のままで起動すること（クライアントバージョンと一致させる）
- ワールドを切り替える場合は `backend-servers.yaml` の `LEVEL_NAME` と展開先ディレクトリ名を同時に変更すること
- 破損バックアップ（`.bak`）はストレージに余裕があれば残しておく（原因分析用）
