# 📝 インシデント・ポストモーテム — BDS 1.26.60 の NetherNet 必須化による Bedrock 参加不能

> **概要**
> このドキュメントは発生した事象を客観的に記録し、再発防止に繋げるためのものです。
> 犯人探しではなく、システムとプロセスの改善（Blameless Postmortem）を目的とします。

---

## 📅 基本情報

| 項目 | 内容 |
|------|------|
| 発生日時 | 2026-10-28 04:00 (JST)（推定。BDS 1.26.60.6 への自動更新） |
| 発覚日時 | 2026-11-03 17:41 (JST)（ユーザー指摘） |
| 解消日時 | 2026-11-03 17:59 (JST)（サーバー側・入口の修正完了。実クライアントでの参加確認は未実施） |
| 影響範囲 | Bedrock サーバー `35.200.78.252:19132` へ全プレイヤーが参加不可（推定約 6.5 日）。Java は 2026-09-30 から計画休止中のため対象外。データ損失なし |
| 対応者 | @Tagomori0211 + Claude Code |

---

## 🔍 1. 何が起きたか（状況）

- **事象概要**:
  - BDS は `itzg/minecraft-bedrock-server:latest` で動いており、毎日 04:00 のバックアップ後の再起動で最新版を取得する。
  - 10/28 に 1.26.60.6、10/30 に 1.26.61.1 へ自動更新された。1.26.60 系から transport の既定が `nethernet` になり、起動ログに次の ERROR が出る。
    `Your current connection type is not set to NetherNet. In this release, NetherNet is the only supported transport type. Players will not be able to connect to your game without NetherNet.`
  - 既存の `server.properties` は `transport=raknet` のままで、入口（mc-gateway の socat）と GCE ファイアウォールも UDP 19132 しか通していなかった。
  - RakNet の ping と OpenConnection には応答し続けたため、MOTD を見る mc-monitor は正常と判定し続け、検知が遅れた。
  - 最後にプレイヤーが参加できた記録は 10/24 23:55（10/25 00:30 退出）。10/25 以降はサーバー側に参加試行のログ自体がない。

- **タイムライン**（JST）:
  - `10/14 04:00`: 1.26.52.3 で TRANSPORT TYPE ERROR が初めて出る。ただしこの時点では RakNet で参加できていた
  - `10/25 00:30`: 最後のプレイヤー退出記録
  - `10/28 04:00`: BDS 1.26.60.6 に自動更新（影響開始と推定）
  - `10/30 04:02`: BDS 1.26.61.1 に自動更新
  - `11/03 17:41`: 接続不通を発見し、調査を開始
  - `11/03 17:43`: Java の不通は計画休止（commit 6118f48）によるもので正常と確認
  - `11/03 17:44`: VictoriaLogs で最後の参加と BDS の更新履歴を特定
  - `11/03 17:45`: RakNet の ping と OpenConnection は公開 IP・Tailscale とも正常。ネットワーク要因を除外
  - `11/03 17:48`: `TRANSPORT=nethernet` を設定し、replicas 0→1 で再起動。ERROR が消える
  - `11/03 17:49`: TCP hostPort が作られていないことを発見（client-side apply が同じ containerPort の TCP エントリを落とした）
  - `11/03 17:50`: server-side apply で入れ直し、Tailscale 経由で TCP 19132 に届くことを確認
  - `11/03 17:57`: mc-gateway に `mc-socat-bedrock-signal.service`（TCP 19132）を配置して起動
  - `11/03 17:59`: Terraform でファイアウォールに tcp:19132 を追加。公開 IP の TCP 19132 で HTTP 応答を確認

---

## 🔬 2. 調査プロセス

### 実行コマンド例

```bash
# 公開 IP / Tailscale 経由の RakNet unconnected ping（自作スクリプト）
python3 rak.py 35.200.78.252 19132
python3 rak.py 100.107.122.45 19132
# → どちらも MCPE;Sushi.ski-Server;2225;1.26.61;... を返す

# RakNet OpenConnectionRequest1 → OpenConnectionReply1 (0x06) が返る = RakNet 層は正常

# BDS のバージョン履歴と最後の参加（VictoriaLogs on mc-gateway）
curl -s http://100.105.149.22:9428/select/logsql/query \
  --data-urlencode 'query=_time:21d "Version:" | fields _time,_msg | sort by (_time)'
curl -s http://100.105.149.22:9428/select/logsql/query \
  --data-urlencode 'query=_time:12d "Player connected" | sort by (_time) desc | limit 5'

# server.properties と同梱ドキュメント
ssh k3s-worker 'sudo kubectl -n minecraft exec deploy/deploy-bedrock -c bedrock -- grep -n ^transport /data/server.properties'
# → transport=raknet

# live の Deployment で ports を確認（TCP が落ちていた）
ssh k3s-worker 'sudo kubectl -n minecraft get deploy deploy-bedrock -o jsonpath="{.spec.template.spec.containers[0].ports}"'
```

- **確認したログの内容**:
  - BDS のバージョン推移: 1.26.52.3（〜10/27）→ 1.26.60.6（10/28〜10/29）→ 1.26.61.1（10/30〜）
  - `Player connected` の最終記録は 2026-10-24 23:55
  - 同梱の `bedrock_server_how_to.html` によれば、NetherNet は server-port の **TCP** で HTTP シグナリングを行い、ゲームプレイは交渉した **UDP** で運ぶ。`server-udp-ports` に公開 IP を書かないと、クライアントにローカルアドレスが広告される

- **特定された原因**:
  - `:latest` による無告知の BDS 更新で NetherNet が必須になった。一方で `transport=raknet` のまま、入口も TCP 19132 を通していなかった
  - 未確認の点がある。同じ ERROR は 1.26.52.3（10/14〜）でも出ていたが、その間も参加できていた。「1.26.60 で RakNet 参加が実際に拒否されるようになった」ことは、実クライアントでの再現でしか確定できない

---

## 🛠️ 3. 対応内容

### 暫定対応（ワークアラウンド）

- [x] なし（下記の恒久対応を直接実施）

### 恒久対応（根本修正）

- [x] `k8s/onprem/backend-servers.yaml`: `TRANSPORT=nethernet`、`SERVER_UDP_PORTS=35.200.78.252:19132:19132` を追加
- [x] `k8s/onprem/backend-servers.yaml`: hostPort 19132/TCP（`bedrock-signal`）を追加。client-side apply ではこの TCP エントリが落ちるため、`kubectl apply --server-side` で適用した
- [x] `gce/gateway/systemd/mc-socat-bedrock-signal.service`: socat TCP 19132 → k3s-worker:19132 を新設し、`cloud-init.yaml` で有効化。mc-gateway には手動で配置済み
- [x] `Terraform/network.tf`: `tak-vpc-allow-minecraft` に tcp:19132 を追加し、apply 済み（in-place 変更 1 件）
- [ ] 実クライアントから `35.200.78.252:19132` に参加できることを確認する（socat 越しの UDP が ICE で通るかは未検証）

---

## 💡 4. 学び・改善点

- [ ] **バージョン固定**: itzg の `VERSION` で BDS を固定し、更新はリリースノートを確認してから手動で行う
- [ ] **監視の強化**: RakNet ping は NetherNet では応答しない。mc-monitor を公開 IP の TCP 19132 への HTTP 応答で生存確認する方式に変え、`BedrockUnjoinableNoMOTD` を見直す（このままでは誤発報する）
- [ ] **監視の強化**: BDS 起動ログの `ERROR` を VictoriaLogs → vmalert → Discord で通知する（10/14 から毎日出ていた）
- [ ] **監視の強化**: 「最後の参加から N 日」の弱いアラートを検討する
- [ ] **プロセスの改善**: Terraform の state を GCS backend に移し、どの clone からでも plan / apply できるようにする（現状は `~/MC_k3s/Terraform` のローカル state のみ）
- [ ] **自動化**: manifest の適用を `kubectl apply --server-side` に統一する（Ansible を含む）。同じ番号の TCP/UDP ポートは client-side apply で落ちる
- [ ] **ドキュメント**: README のゲームトラフィック図と `gce/README.md` に 19132/TCP（シグナリング）を追記する

---

*Created by: Tagomori0211 + Claude Code*
