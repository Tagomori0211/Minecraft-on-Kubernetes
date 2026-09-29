# 📝 インシデント・ポストモーテム: Bedrock版 接続障害 & Vibrant Visuals グレーアウト

> **概要**
> このドキュメントは発生した事象を客観的に記録し、再発防止に繋げるためのものです。
> 犯人探しではなく、システムとプロセスの改善（Blameless Postmortem）を目的とします。

---

## 📅 基本情報

| 項目 | 内容 |
|------|------|
| 発生日時 | 2026-03-23 〜 2026-03-27 |
| 解消日時 | 2026-03-27 12:30 (JST) (VV問題は暫定対応) |
| 影響範囲 | Bedrock版サーバー: マルチプレイ接続不可 → ワールドクラッシュ → VVグレーアウト |
| 対応者 | @Tagomori0211 / Claude  / Antigravity AI |

---

## 🔍 1. 何が起きたか（状況）

本インシデントは複数の事象が連鎖的に発生した複合障害であり、4つの独立した問題が順番に表面化した。

- **事象概要**:
  1. **Vibrant Visuals（VV）グレーアウト**: Bedrock版クライアントでGraphics ModeからVibrant Visualsが選択できない
  2. **マルチプレイ接続不可**: 「クライアントがマルチプレイサービスへの接続を確立できません」エラー
  3. **ワールドデータ破損**: BDS 1.26.11.1 がプレイヤースポーン直後に `gsl::narrowing_error` でクラッシュ
  4. **VVグレーアウト（再発）**: ワールド復旧後、リソースパック起因でVVが再びグレーアウト

- **タイムライン**:
  - `03-23`: VVグレーアウトの調査を開始。リソースパック(Nasu Golem)の manifest.json 修正を試行
  - `03-26 03:39`: VV調査中の構成変更に起因し、Bedrock版マルチプレイ接続が完全に不通となる
  - `03-26 04:44`: GCP Firewall に UDP 19132 の外部許可がないことを特定
  - `03-26 06:01`: Nginx GW → オンプレ間で `Connection refused` エラーを確認。Tailscale `--accept-routes=false` を特定
  - `03-26 13:56`: bedrock-relay (L7) と Nginx L4 直の構成が混在していることを発見。bedrock-relay 経由に切り替え
  - `03-26 14:28`: bedrock-relay でXUID消失を確認 (`Player connected: Unknown`)。L4 直に再切り替え
  - `03-27 09:53`: Tailscale `--accept-routes=true` 設定後、パケットがオンプレまで到達開始。ただしNginx Stream UDPがソースポートを書き換えるため数秒で切断
  - `03-27 10:14`: socat サイドカーによるUDP透過転送に切り替え。XUID正常通過を確認 (`xuid: 2533274899355289`)
  - `03-27 10:29`: BDS 1.26.11.1 がプレイヤースポーン直後に `gsl::narrowing_error` でクラッシュ。パック無関係、ワールドデータ破損と特定
  - `03-27 10:47`: 新規ワールドで正常スポーン・2分間探索問題なし。ワールドデータ破損確定
  - `03-27 11:02`: mcworld バックアップからワールド復旧完了。接続・スポーン正常化
  - `03-27 11:07`: VVグレーアウトが再発。server.properties の `disable-client-vibrant-visuals=false` は反映済み
  - `03-27 11:31`: Nasu Golem リソースパックがVV無効化の原因と特定（パック除去でVV有効）
  - `03-27 12:25`: manifest.json の `pbr` + `product_type: addon` 修正、キャッシュ削除、サーバールート配置等を試行するもBDS経由ではVVグレーアウト解消せず
  - `03-27 12:30`: 暫定対応として Nasu Golem をワールドリソースから除外し、クライアント側グローバルリソースパックとして各プレイヤーに適用する方式に決定

---

## 🔬 2. 調査プロセス

### 問題1: GCP Firewall UDP 未許可

```bash
gcloud compute firewall-rules list --filter="name~minecraft OR name~tak-vpc"
# → tak-vpc-allow-minecraft: tcp:25565 のみ許可。udp:19132 がない
```

- **原因**: Terraform定義 (`gke.tf`) の `google_compute_firewall.minecraft_tcp` が TCP 25565 のみ定義。Bedrock用 UDP Firewall ルールが未定義だった

### 問題2: Tailscale accept-routes

```bash
tailscale status
# → "Some peers are advertising routes but --accept-routes is false"

sudo timeout 30 tcpdump -i tailscale0 udp port 19132 -c 5
# → 0 packets captured（tailscale0にパケットが到達しない）

sudo timeout 30 tcpdump -i any udp port 19132 -c 5
# → 2 packets received by filter, 0 packets captured（カーネルでドロップ）
```

- **原因**: オンプレ k3s-worker の Tailscale が `--accept-routes=false` のままで、GKE Subnet Router からの戻り経路が確立されていなかった

### 問題3: Nginx Stream UDP ソースポート書き換え

```bash
sudo timeout 60 tcpdump -i tailscale0 udp port 19132 -c 20
# → GKE側のソースポートが 43968, 32940, 35720 と接続ごとに変化
# → RakNet ステートフルセッションが破壊される
```

- **原因**: Nginx Stream の UDP プロキシは新しいパケットごとに異なるソースポートで upstream セッションを作成する。RakNet（Bedrock Edition の通信プロトコル）はステートフルなUDPプロトコルであり、ソースポートの一貫性が必須

### 問題4: ワールドデータ破損

```
[2026-03-27 10:29:09:890 INFO] Player connected: Shinari5295, xuid: 2533274899355289
[2026-03-27 10:29:10:061 INFO] Player PartyIdUpdate:  pfid: 601402B967213764, partyid: 
libc++abi: terminating due to uncaught exception of type gsl::narrowing_error: narrowing_error
```

- **原因**: 既存ワールド「Bedrock level」のデータに破損があり、BDS 1.26.11.1 のプレイヤースポーン処理で数値変換エラー（narrowing_error）が発生。新規ワールドでは問題なし

### 問題5: VV グレーアウト（リソースパック起因）

```bash
# パックあり → VVグレーアウト
# world_resource_packs.json を [] にする → VV有効
# ローカルシングルプレイでは manifest.json 修正後にVV有効
# BDS経由では同じ manifest.json でもVVグレーアウト
```

- **原因**: BDS がリソースパックの `pbr` ケイパビリティを正しく評価せず、クライアントに「VV非対応」として通知する。ローカルクライアントとBDSで評価ロジックが異なる（BDS側の制限/バグの可能性）

---

## 🛠️ 3. 対応内容

### 恒久対応（完了）

- [x] **GCP Firewall**: `tak-vpc-allow-minecraft` に `udp:19132` を追加（`gcloud compute firewall-rules update`）
- [x] **Tailscale accept-routes**: オンプレ k3s-worker で `sudo tailscale set --accept-routes=true` を実行
- [x] **socat UDP 透過転送**: Nginx GW Pod に `bedrock-udp-relay` サイドカーコンテナを追加。Nginx の Bedrock UDP 設定を削除し、socat (`UDP4-LISTEN:19132,fork,reuseaddr → UDP4:100.100.135.81:19132`) で完全透過転送。XUID 保全を確認済み
- [x] **bedrock-relay 停止**: 不要となった L7 プロキシ（bedrock-relay Deployment）を replicas=0 にスケールダウン
- [x] **ワールド復旧**: mcworld バックアップから PVC にワールドデータをリストア。破損ワールドは `.corrupted.bak` としてバックアップ保全
- [x] **BDS server.properties**: `disable-client-vibrant-visuals=false` を明示設定

### 暫定対応（VV問題）

- [x] **Nasu Golem をワールドリソースから除外**: `world_resource_packs.json` を `[]` に設定してVVを有効化
- [x] **クライアント側グローバルリソースパック方式に移行**: Nasu Golem は各プレイヤーが手動でグローバルリソースパックとして適用。配布先: https://potatotime.booth.pm/items/7675922

### 未対応（要恒久対応）

- [ ] **Terraform 更新**: `gke.tf` の Firewall 定義に `udp:19132` を追加してコード化
- [ ] **backend-servers.yaml 更新**: BDS Pod の `hostPort: 19132` を YAML に明記
- [ ] **20-nginx-gw.yaml 更新**: socat サイドカーをマニフェストに反映
- [ ] **Tailscale 設定の IaC 化**: `--accept-routes=true` を Ansible Playbook に追加

---

## 💡 4. 学び・改善点

- [ ] **Nginx Stream は RakNet 非互換**: Bedrock Edition の UDP 転送に Nginx Stream を使ってはならない。socat (`fork,reuseaddr`) または専用 UDP フォワーダーを使用すること。これはポストモーテム「[postmortem-waterdogpe-already-connected.md](postmortem-waterdogpe-already-connected.md)」で L7 プロキシの排除は結論済みだったが、L4 プロキシ（Nginx Stream）のソースポート書き換え問題は新たな知見
- [ ] **GCP Firewall の UDP 許可漏れ検知**: Terraform の Firewall 定義に UDP ルールが含まれているかの CI チェックを追加する
- [ ] **Tailscale accept-routes の自動設定**: オンプレノードの Tailscale 設定を Ansible で管理し、`--accept-routes=true` が確実に適用されるようにする
- [ ] **BDS リソースパックの VV 互換性**: BDS（サーバー側）はローカルクライアントと異なるリソースパック評価ロジックを持つ。VV 対応が必要なリソースパックは `world_resource_packs.json` ではなくクライアント側グローバルリソースパックとして配布する運用が安全
- [ ] **ワールドバックアップの定期化**: rclone/GCS バックアップ（Phase 2 ロードマップ）の実装を早期に進め、今回のようなワールド破損時の復旧を迅速化する
- [ ] **構成変更時の影響範囲評価**: VV 調査のような「設定確認のみ」の作業でも、Pod 再起動や構成変更を伴う場合はサービス影響を事前に評価し、作業前の接続テストを必ず実施する

---

*Created by: @Tagomori0211 / Claude *
