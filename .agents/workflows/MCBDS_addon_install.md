---
description: Install Bedrock Addon (.mcpack / .mcaddon) to k3s Bedrock Server
---

このワークフローは、`.mcpack` または `.mcaddon` 形式の Bedrock 専用アドオンをオンプレミスの k3s Bedrock サーバーに導入する手順をまとめます。

**前提:**
- kubectl はすべて `ssh k3s-worker 'sudo kubectl ...'` 経由で実行する（クライアントから直接実行不可）
- 導入するアドオンファイルが `MC_addon-raw/` に配置済みであること
- ワールド名は `sushi_server`（`k8s/onprem/backend-servers.yaml` の `LEVEL_NAME` と同じ）

---

## 1. アドオンの解凍と構造確認

アドオンは ZIP 形式のため、手元で解凍します。

```bash
mkdir -p tmp_addon
```

```bash
unzip -o MC_addon-raw/YOUR_ADDON.mcpack -d tmp_addon/
```

```bash
cat tmp_addon/manifest.json
```

`manifest.json` 内の `header.uuid` と `header.version`、`modules` の type（`resources` / `data`）を確認します。

---

## 2. Bedrock Pod 名の取得

```bash
POD=$(ssh k3s-worker 'sudo kubectl get pod -n minecraft -l app=mc-bedrock -o jsonpath="{.items[0].metadata.name}"')
```

```bash
echo $POD
```

---

## 3. k3s ワーカーノードへ転送し Pod に配置

```bash
scp -r tmp_addon k3s-worker:/tmp/addon_extracted
```

リソースパックの場合は `resource_packs`、ビヘイビアーパックは `behavior_packs` に配置します（以下はリソースパックの例）。

```bash
ssh k3s-worker "sudo kubectl exec -n minecraft $POD -c bedrock -- \
  mkdir -p '/data/resource_packs/addon_folder'"
```

```bash
ssh k3s-worker "sudo kubectl cp /tmp/addon_extracted \
  minecraft/$POD:/data/resource_packs/addon_folder -c bedrock"
```

---

## 4. world_resource_packs.json への登録

**注意:** VV（Vibrant Visuals）を有効にしたい場合、サーバー側 world_resource_packs.json にリソースパックを登録すると VV がグレーアウトする（BDS の既知制約）。
VV との共存が必要なパックは **クライアント側グローバルリソースパック**として配布すること。

VV 不要なパックの場合のみ以下を実施します。

```bash
echo '[{"pack_id": "YOUR-UUID-HERE", "version": [1, 0, 0]}]' > tmp_packs.json
```

```bash
scp tmp_packs.json k3s-worker:/tmp/packs.json
```

```bash
ssh k3s-worker "sudo kubectl cp /tmp/packs.json \
  minecraft/$POD:/data/worlds/sushi_server/world_resource_packs.json -c bedrock"
```

---

## 5. パーミッションの修正

```bash
ssh k3s-worker "sudo kubectl exec -n minecraft $POD -c bedrock -- \
  chown -R 1000:1000 /data/worlds/sushi_server"
```

---

## 6. サーバーの再起動

BDS は `rollout restart` 禁止。replicas=0 → 1 で完全再起動します。
プレイヤーが接続中の可能性がある場合は `.claude/commands/bedrock-restart.md` のアナウンス付き手順を使うこと。

```bash
ssh k3s-worker 'sudo kubectl scale deployment deploy-bedrock -n minecraft --replicas=0'
```

```bash
ssh k3s-worker "sudo kubectl wait --for=delete pod/$POD -n minecraft --timeout=60s"
```

```bash
ssh k3s-worker 'sudo kubectl scale deployment deploy-bedrock -n minecraft --replicas=1'
```

---

## 7. 一時ファイルの削除

```bash
rm -rf tmp_addon tmp_packs.json
```

```bash
ssh k3s-worker 'rm -rf /tmp/addon_extracted /tmp/packs.json'
```

---

## 8. 起動確認

```bash
ssh k3s-worker 'sudo kubectl logs deploy/deploy-bedrock -c bedrock -n minecraft --tail=20'
```

`Server started.` が表示されれば成功です。
