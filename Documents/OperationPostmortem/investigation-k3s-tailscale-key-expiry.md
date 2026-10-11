# 🔎 原因調査レポート — Bedrock 接続不能（k3s-worker の Tailscale ノードキー失効）

> 対応するポストモーテム: [postmortem-k3s-tailscale-key-expiry.md](postmortem-k3s-tailscale-key-expiry.md)
> 調査日時: 2026-10-12 01:53〜02:15（JST）/ 調査: Claude Code（依頼: @Tagomori0211）

---

## 結論

- **BDS（Bedrock Pod）は最初から最後まで正常に動いていた。** 止まっていたのは k3s-worker と GCE mc-gateway をつなぐ **Tailscale** だった。
- k3s-worker の Tailscale ノードキーが **2026-10-11 21:32:37 JST に期限切れ** になり、k3s-worker は tailnet から外れた（`NeedsLogin`）。
- このノードキーは 2026-04-14 21:32:37 JST に手動承認で発行されたもので、ユーザー所有のデバイスに付く **既定の有効期限 180 日** を迎えて失効した。
- 入口（35.200.78.252:19132 → mc-socat-bedrock → `100.107.122.45:19132`）が届かなくなり、Bedrock には外から一切つながらなくなった。
- Pod は `Running`・再起動 0 回・エラーログなしのため、kubectl から見ると「生きているのに誰も入れない」状態になっていた。
- 2026-10-12 02:09 にユーザーが再認証して復旧した（IP は変わらず）。続けて key expiry を無効化したので、同じ原因では再発しない（9 章）。

---

## 1. 調査開始時点の状態（2026-10-12 01:53 JST）

| 観点 | 観測 | 判定 |
|------|------|------|
| Pod | `deploy-bedrock-8559fffd-vrfnk` 2/2 Running、RESTARTS 0、起動は 10/11 04:02（日次バックアップの停止→起動） | 正常 |
| BDS ログ | 04:02 に `Server started.` のあと、約 40 分ごとの `Running AutoCompaction...` が 01:51 まで続いている | プロセス生存 |
| namespace のイベント | なし | 異常なし |
| mc-monitor（Pod 内エクスポーター） | `healthy=0` / `responding=0` / `motd_present=0`（35.200.78.252 への ping に応答なし） | **外から到達不能** |

---

## 2. 経路の切り分け

RakNet Unconnected Ping（mc-monitor の `monitor.py` の `ping()` と同じ処理）を手元から送り、経路の内側から順に確かめた。

| 宛先 | 通る経路 | 結果 |
|------|----------|------|
| `192.168.0.151:19132` | LAN → hostPort → BDS | ✅ PONG 0.8ms、MOTD `MCPE;Sushi.ski-Server;…;1.26.52;0;25;…` |
| `100.107.122.45:19132` | Tailscale → hostPort → BDS | ❌ TIMEOUT |
| `35.200.78.252:19132` | GCE mc-socat-bedrock → Tailscale → BDS | ❌ TIMEOUT |

→ BDS 本体・hostPort は正常。**Tailscale の区間で途切れている**。

### k3s-worker 側

```console
$ ssh k3s-worker 'tailscale status'
Logged out.
Log in at: https://login.tailscale.com/a/<redacted>

$ ssh k3s-worker 'tailscale ip -4'
no current Tailscale IPs; state: NeedsLogin
```

### mc-gateway 側（IAP SSH）

- `mc-socat-java` / `mc-socat-bedrock` / `mc-discord-notifier` / `tailscaled` はすべて active
- メモリ available 438MB / swap 299MB 使用、監視スタックのコンテナは 12 日間連続稼働
- `tailscale status` で `k3s-worker-1 … offline, last seen 3h ago`

→ mc-gateway は健全。k3s-worker だけが tailnet から外れている。

---

## 3. 根本原因の特定

### 3.1 tailscaled のログ（k3s-worker）

```text
2026-10-11T12:32:37Z tailscaled: Switching ipn state Running -> NeedsLogin (WantRunning=true, nm=true)
2026-10-11T12:32:37Z tailscaled: magicsock: SetPrivateKey called (zeroed)
2026-10-11T12:32:37Z tailscaled: magicsock: closing connection to derp-7 (zero-private-key), age 595h3m58s
   … （1 時間後、Tailscale の自動更新で tailscaled が再起動）
2026-10-11T13:32:37Z tailscaled: offline auto-update: running "systemd-run --wait --pipe --collect /usr/bin/tailscale update --yes"
2026-10-11T13:32:39Z dpkg: upgrade tailscale:amd64 1.102.2 1.104.1
2026-10-11T13:32:43Z tailscaled: control: RegisterReq: got response; nodeKeyExpired=true, machineAuthorized=true; authURL=false
2026-10-11T13:32:43Z tailscaled: control: server reports new node key [eLTEW] has expired
2026-10-11T13:32:43Z tailscaled: control: Generating a new nodekey.
2026-10-11T13:32:43Z tailscaled: control: RegisterReq: got response; nodeKeyExpired=false, machineAuthorized=false; authURL=true
2026-10-11T13:32:43Z tailscaled: Switching ipn state NoState -> NeedsLogin (WantRunning=true, nm=false)
```

- 21:32:37 JST に `Running → NeedsLogin` へ遷移し、WireGuard の秘密鍵がゼロクリアされている（tailnet から外れた瞬間）。
- 再起動後の登録要求に対し、コントロールサーバーは `nodeKeyExpired=true` と返している（**ノードキーの期限切れ**）。

### 3.2 コントロールサーバー側の記録（mc-gateway から見た peer 情報）

```text
SELF gce-mc-gateway  Tags=['tag:k3s-worker']  KeyExpiry=None
PEER k3s-worker      100.107.122.45  KeyExpiry=2026-10-11T12:32:37Z  Expired=True  Online=False  Tags=None
```

- k3s-worker は **タグなし（ユーザー所有）** のため、ノードキーに有効期限が付いていた。
- mc-gateway はタグ付きデバイスなので有効期限がない（Tailscale の仕様: タグを付けて認証したデバイスは key expiry が既定で無効）。

### 3.3 180 日の起点

```console
$ TZ=Asia/Tokyo date -d '2026-10-11T12:32:37Z - 180 days'
2026-04-14 21:32:37 JST
```

- 2026-04-14 は [costcut-incident.md](costcut-incident.md) の障害対応日で、「ユーザーによる VPN 手動承認完了。新 IP `100.107.122.45` 割り当て」と記録されている。
- 2 分半後の **21:35:10 にコミット `8f01b6b`（"Updated all proxy and service configs to use new IP 100.107.122.45"）** があり、承認時刻と合う。
  - costcut-incident.md のタイムラインでは承認は `22:33` とあるが、失効時刻から逆算した発行時刻とコミット時刻から、実際は 21:32:37 と判断した。
- 失効時刻はちょうど 180 日後。tailnet の key expiry は既定値（180 日）のまま。

---

## 4. 因果連鎖

```
2026-04-14 21:32:37  障害対応中に k3s-worker を対話ログインで手動承認（タグなし＝ユーザー所有デバイス）
  └─ ノードキーに既定の有効期限 180 日が付く（期限を記録・監視する仕組みはなかった）
       └─ 2026-10-11 21:32:37  ノードキー失効 → tailscaled が NeedsLogin、tailscale0 から 100.107.122.45 が消える
            ├─ mc-socat-bedrock（GCE）→ 100.107.122.45:19132 が届かない → Bedrock に外から接続できない
            ├─ vmagent / Vector / bq-metrics → 100.105.149.22（mc-gateway）が届かない → 監視データが途絶
            └─ BDS 自体は無傷 → Pod は Running・再起動なし・エラーログなし（＝kubectl では異常が見えない）
```

---

## 5. 除外した仮説

| 仮説 | 根拠 | 判定 |
|------|------|------|
| BDS のクラッシュ・OOM | RESTARTS 0、AutoCompaction のログが継続、LAN からの ping に MOTD 付きで応答 | ❌ 無関係 |
| BDS 1.26.52.3 の `TRANSPORT TYPE ERROR`（NetherNet 必須の警告） | 同じ 1.26.52.3 + `transport=raknet` のまま、10/10 23:04〜10/11 01:37 にプレイヤーが接続できている。復旧後も入口から MOTD 付きで応答 | ❌ 無関係（別リスクとして 8 章に記載） |
| mc-gateway のメモリ逼迫・socat 停止 | available 438MB、全 unit active、コンテナ 12 日間連続稼働 | ❌ 無関係 |
| Tailscale 自動更新（1.102.2 → 1.104.1） | 更新は失効の 1 時間後（22:32 JST）。失効は更新前の 21:32:37 に起きている | ❌ 引き金ではない（再起動で失効が確定表示されただけ） |
| 日次バックアップによる Pod 停止 | 04:00〜04:02 の計画停止のみ。その後もプレイヤー接続あり | ❌ 無関係 |
| 21:05〜21:06 JST の ping 欠落 | 15 秒ごとの ping が 1〜2 回失敗しただけで、すぐ回復。失効の 27 分前で、その後は 21:32:36 まで正常 | ❌ 一過性（本件とは別） |

---

## 6. 「黙って死んでいる」ように見えた理由

1. **Kubernetes から見ると正常**: 壊れたのは Pod の外（ノードの Tailscale）で、Pod の中の BDS は正常なままだった。Pod は Running・再起動 0 のままで、仮に probe を付けていても Pod の中からは検知できない種類の障害だった。
2. **Bedrock 用のアラートは原理的に鳴らない**: `MinecraftServerDown` / `BedrockUnjoinableNoMOTD` の元になる mc-monitor のメトリクスは k3s で作られ、**止まったのと同じ Tailscale 経由**で mc-gateway に送られる。mc-monitor 自身は `healthy=0` を出していたが、その値が mc-gateway の VictoriaMetrics に届かなかった。
   - 最後に届いたサンプルは `up{job="bedrock"}` の 2026-10-11 21:32:36 JST（失効の 1 秒前）。
3. **鳴ったのは汎用アラートだけ**: 途絶検知の `OnpremSilence`（`absent(up{location="onprem"} == 1)`）は正しく動いた。
   - 21:38:00 pending → **21:43:00 firing**。障害中の Discord 送信は 2 回（初回 21:43 頃、4 時間後の再通知 01:43 頃）で、失敗は 0。
   - ただし内容は「オンプレ k3s 沈黙（vmagent / k3s / Tailscale 障害の可能性）」で、Bedrock が入れないことも、ノードキーの失効であることも分からない。
4. **期限を見張る仕組みがなかった**: 既存の `TailscaleAuthKeyExpiringSoon` は mc-gateway 再作成用の **auth key**（Secret Manager）の期限を見るもので、**各デバイスのノードキー**は対象外。しかも Discord 通知は抑止されている。

---

## 7. 影響

| 対象 | 影響 |
|------|------|
| Bedrock プレイヤー | 2026-10-11 21:32:37 〜 2026-10-12 02:09:32 JST（約 4 時間 37 分）接続不能（直前に接続できたセッションは 10/10 23:04〜10/11 01:37） |
| VictoriaMetrics（mc-gateway） | 障害中は k3s 由来のメトリクスが途絶。vmagent が溜めた送信待ちを復旧後に送り、データは後から埋まった |
| BigQuery（bq-metrics） | 15 秒ごとに「今」の値を問い合わせる方式のため、障害中は欠測（後から埋めない） |
| VictoriaLogs | 障害中は途絶。復旧後に Vector の再送で届いた |
| 影響なし | Pub/Sub へのログイン/ログアウト転送（mc-log-shipper）、GCS バックアップ、mc-gateway 上の各サービス、Java（休眠中） |

---

## 8. 調査中に見つかった別のリスク（本件の原因ではない）

1. **BDS の transport 既定値が `nethernet` になっている**
   - 同梱の `bedrock_server_how_to.html` では `transport` の既定が `nethernet`（WebRTC ベース）、`raknet` は「NetherNet が既定になる前のリリースで使われていた方式」と説明されている。
   - 現在 RakNet で動いているのは、PVC 上の `server.properties` に `transport=raknet` が書かれているため（2026-06-21 に手動で追加。マニフェストには書かれていない）。
   - PVC を作り直すと既定の NetherNet で起動し、socat の UDP 透過転送が使えなくなるおそれがある。`itzg/minecraft-bedrock-server:latest` は毎日 04:00 の再起動で BDS を自動更新するため、将来のリリースで RakNet が外されると予告なく止まる。
2. **Ansible の Tailscale 設定が実態とずれている**: `Ansible/install_k3s.yml` は `--hostname=tak-onprem-mc --advertise-routes=10.43.0.0/16` で auth key 認証するが、実機はホスト名指定なし・経路広告なし・対話ログインで参加している。このまま作り直しても有効期限付きのノードになる。
3. **vmagent の送信待ちデータが emptyDir に乗っていない**: `vmagent-wal` を `/tmp/vmagent-wal` にマウントしているが `-remoteWrite.tmpDataPath` を指定していないため、実際の保存先はコンテナ内の `/vmagent-remotewrite-data`。障害中に vmagent コンテナが再起動すると、送信待ちのデータが消える。
4. **tailnet 上の `mc-server`（100.102.92.22）も 2026-08-27 にノードキー失効したまま**: 今の構成では使っていないとみられるが、必要かどうかを確認し、不要なら削除する。

---

## 9. 復旧手順と確認結果

### 9.1 再認証（ユーザー作業）

`tailscale status` が出していた認証 URL を、tailnet の所有アカウントでユーザーが承認した。
デバイスは**削除せずに**再認証している（削除すると新しいデバイスとして登録され、IP が変わる）。

```text
2026-10-11T17:09:30Z tailscaled: control: RegisterReq: got response; nodeKeyExpired=false, machineAuthorized=true; authURL=false
2026-10-11T17:09:30Z tailscaled: Switching ipn state NeedsLogin -> Starting (WantRunning=true, nm=true)
2026-10-11T17:09:32Z tailscaled: Switching ipn state Starting -> Running (WantRunning=true, nm=true)
```

- 02:09:32 JST に `Running` へ復帰。`tailscale ip -4` は `100.107.122.45` のままで、GCE 側の socat の宛先を直す必要はなかった。
- `tailscale ping 100.105.149.22` → `pong from gce-mc-gateway (100.105.149.22) via 35.200.78.252:41641 in 20ms`（direct 接続）。

### 9.2 Bedrock の到達性

| 宛先 | 復旧前 | 復旧後 |
|------|--------|--------|
| `192.168.0.151:19132`（LAN） | ✅ | ✅ 0.4ms |
| `100.107.122.45:19132`（Tailscale） | ❌ TIMEOUT | ✅ 40.7ms、MOTD あり |
| `35.200.78.252:19132`（GCE 入口） | ❌ TIMEOUT | ✅ 42.4ms、MOTD あり |

- mc-monitor も 02:10:21 JST に `healthy=1` / `responding=1` / `motd_present=1` へ戻った。
- BDS は終始正常だったため、Pod は再起動していない。

### 9.3 key expiry の無効化（ユーザー作業）

| 時点 | mc-gateway から見た `k3s-worker` の `KeyExpiry` |
|------|-------------------------------------------|
| 失効時 | `2026-10-11T12:32:37Z`（`Expired=True`） |
| 再認証直後 | `2027-04-09T17:09:29Z`（新たに 180 日） |
| 無効化後（02:11 までに確認） | `None`（期限なし） |

### 9.4 監視の回復

| 項目 | 結果 |
|------|------|
| vmagent | 障害中に溜めた送信待ち（書き込み 22.7MB）を約 120KB/s で送り直し、02:13:01 に未送信 0。復旧後の再送回数の増加なし |
| VictoriaMetrics | 障害中のメトリクスも後から埋まった（Grafana で `healthy=0` の期間を後から確認できる） |
| vmalert | `OnpremSilence` は 02:11:30 の評価を最後に firing から外れ、02:12:00 に解消 |
| Alertmanager | 02:15 までに Discord へ resolved 通知を送信（累計 3 回、失敗 0） |
| 後から届いたデータの影響 | 障害中の `healthy=0`（`server_version="1.26.52.3"` の系列）が後から届いたため、`MinecraftServerDown` が 02:12 に pending になった。`for: 5m` を満たす前に条件を外れ、発火していない（02:15 時点でアラートなし） |
| VictoriaLogs | 障害中（21:32〜02:09）のログ 2,080 件も、Vector の再送で後から届いた |
| bq-metrics | 02:13:02 から BigQuery への書き込みが再開。障害中の分は欠測のまま（後から埋める仕組みはない） |

補足: mc-monitor は ping に失敗すると `server_version` ラベルを MOTD の値（`1.26.52`）から BDS のファイル名の値（`1.26.52.3`）に切り替えるため、ping の成否で別の系列になる。復旧直後の一時的な pending や、21:05 の一過性の欠落が別系列に見えたのはこのため。

---

## 付録: 調査で実行した主なコマンド

```bash
# Pod・ログ・エクスポーターの確認
ssh k3s-worker 'sudo kubectl get pods -n minecraft -o wide'
ssh k3s-worker 'sudo kubectl logs -n minecraft deploy/deploy-bedrock -c bedrock --tail=80 --timestamps'
ssh k3s-worker 'sudo kubectl exec -n minecraft deploy/deploy-bedrock -c mc-monitor -- wget -qO- http://127.0.0.1:8080/metrics'

# 経路ごとの RakNet ping（LAN / Tailscale / GCE 入口）。処理は monitor.py の ping() と同じ
#   192.168.0.151:19132 / 100.107.122.45:19132 / 35.200.78.252:19132

# k3s-worker の Tailscale 状態とログ
ssh k3s-worker 'tailscale status'
ssh k3s-worker 'sudo journalctl -u tailscaled --since "2026-10-11 12:25:00" --until "2026-10-11 13:40:00"'
ssh k3s-worker 'grep tailscale /var/log/dpkg.log'

# mc-gateway（IAP SSH）: サービス・アラート・peer のキー期限
ssh k3s-worker 'gcloud compute ssh mc-gateway --zone=asia-northeast1-b --tunnel-through-iap --command="systemctl is-active mc-socat-java mc-socat-bedrock; free -m; tailscale status"'
ssh k3s-worker 'gcloud compute ssh mc-gateway --zone=asia-northeast1-b --tunnel-through-iap --command="curl -s 127.0.0.1:8880/api/v1/alerts; curl -s 127.0.0.1:9093/api/v2/alerts"'
ssh k3s-worker 'gcloud compute ssh mc-gateway --zone=asia-northeast1-b --tunnel-through-iap --command="tailscale status --json"'   # Peer[].KeyExpiry / Expired / Tags

# 途絶時刻（最後に届いたサンプルの時刻）
curl -s 127.0.0.1:8428/api/v1/query --data-urlencode 'query=tlast_over_time(up{location="onprem"}[12h])'

# 180 日の逆算
TZ=Asia/Tokyo date -d '2026-10-11T12:32:37Z - 180 days'
```
