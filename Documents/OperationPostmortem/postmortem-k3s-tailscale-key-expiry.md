# 📝 インシデント・ポストモーテム — k3s-worker の Tailscale ノードキー失効による Bedrock 接続不能

> **概要**
> このドキュメントは発生した事象を客観的に記録し、再発防止に繋げるためのものです。
> 犯人探しではなく、システムとプロセスの改善（Blameless Postmortem）を目的とします。

---

## 📅 基本情報

| 項目 | 内容 |
|------|------|
| 発生日時 | 2026-10-11 21:32 (JST) |
| 解消日時 | 2026-10-12 02:09 (JST) (所要時間: 277分) |
| 影響範囲 | Bedrock サーバーへの外部からの接続がすべて不可。k3s → mc-gateway の監視データ（メトリクス・ログ・BigQuery 連携）が途絶。Java は休眠中のため影響なし |
| 対応者 | @Tagomori0211 + Claude Code |

---

## 🔍 1. 何が起きたか（状況）

- **事象概要**:
  - k3s-worker の Tailscale ノードキーが期限切れになり、k3s-worker が tailnet から外れた。
  - GCE mc-gateway の `mc-socat-bedrock` は `100.107.122.45:19132` へ転送できなくなり、`35.200.78.252:19132` から Bedrock に入れなくなった。
  - BDS 自体は正常に動き続けていたため、Pod は `Running`・再起動 0 回・エラーログなしで、kubectl からは異常が見えなかった（「黙って死んでいる」ように見えた）。
  - ノードキーは 2026-04-14 の障害対応で対話ログイン（手動承認）したときに発行されたもので、ユーザー所有デバイスの既定の有効期限 180 日を迎えて失効した。

- **タイムライン**（JST）:
  - `04/14 21:32`: （背景）別障害の対応中に k3s-worker を Tailscale へ手動承認で再参加させる。タグなしのため有効期限 180 日のノードキーが付く
  - `10/11 21:32`: ノードキー失効。k3s-worker が `NeedsLogin` になり、Bedrock への外部接続と監視データの送信が止まる
  - `10/11 21:43`: vmalert `OnpremSilence` が firing → Discord へ通知（内容は「オンプレ k3s 沈黙」のみ）
  - `10/11 22:32`: Tailscale の自動更新（1.102.2 → 1.104.1）で tailscaled が再起動。コントロールサーバーが `nodeKeyExpired=true` を返し、再認証待ちのまま
  - `10/12 01:43`: `OnpremSilence` の再通知（4 時間間隔）
  - `10/12 01:53`: ユーザー指摘（「BEのpod黙って死んでる」）、初動調査開始
  - `10/12 01:56`: 経路の切り分けで、BDS は LAN から応答する一方、k3s-worker の Tailscale が `NeedsLogin` と判明
  - `10/12 01:59`: tailscaled のログとコントロールサーバーの `KeyExpiry` から、ノードキー失効（発行からちょうど 180 日）と確定
  - `10/12 02:05`: ユーザーに再認証と key expiry の無効化を依頼
  - `10/12 02:09`: ユーザーが認証 URL を承認し、k3s-worker が `Running` に復帰（IP `100.107.122.45` は維持）。GCE 入口 `35.200.78.252:19132` から MOTD 付きの応答を確認（**復旧**）
  - `10/12 02:11`: key expiry の無効化を確認（mc-gateway から見た peer の `KeyExpiry=None`）
  - `10/12 02:12`: `OnpremSilence` が解消。障害中の `healthy=0` が後から届いたため `MinecraftServerDown` が一時的に pending になったが、発火前に消えた
  - `10/12 02:13`: vmagent が溜めていた送信待ち（22.7MB）を送り切り、bq-metrics の BigQuery 書き込みも再開
  - `10/12 02:15`: Discord への resolved 通知と、アラートがすべて消えたことを確認（監視の復旧確認）

---

## 🔬 2. 調査プロセス

経路の内側から順に切り分けた。詳細なログ・判断根拠・除外した仮説は [investigation-k3s-tailscale-key-expiry.md](investigation-k3s-tailscale-key-expiry.md) にまとめた。

### 実行コマンド例

```bash
# Pod・BDS ログ・エクスポーターの確認
ssh k3s-worker 'sudo kubectl get pods -n minecraft -o wide'
ssh k3s-worker 'sudo kubectl logs -n minecraft deploy/deploy-bedrock -c bedrock --tail=80 --timestamps'
ssh k3s-worker 'sudo kubectl exec -n minecraft deploy/deploy-bedrock -c mc-monitor -- wget -qO- http://127.0.0.1:8080/metrics'

# 経路ごとの RakNet ping: 192.168.0.151（LAN）/ 100.107.122.45（Tailscale）/ 35.200.78.252（GCE 入口）

# k3s-worker の Tailscale 状態とログ
ssh k3s-worker 'tailscale status'
ssh k3s-worker 'sudo journalctl -u tailscaled --since "2026-10-11 12:25:00" --until "2026-10-11 13:40:00"'

# mc-gateway（IAP SSH）: 入口・アラート・peer のキー期限
ssh k3s-worker 'gcloud compute ssh mc-gateway --zone=asia-northeast1-b --tunnel-through-iap --command="systemctl is-active mc-socat-bedrock; curl -s 127.0.0.1:8880/api/v1/alerts; tailscale status --json"'
```

- **確認したログの内容**:
  - Pod は 2/2 Running・RESTARTS 0。BDS は `Server started.` 後も `Running AutoCompaction...` を出し続けており、プロセスは生きていた
  - mc-monitor は `healthy=0` / `responding=0`（35.200.78.252 への ping に応答なし）
  - RakNet ping は LAN（192.168.0.151）では MOTD 付きで応答、Tailscale（100.107.122.45）と GCE 入口（35.200.78.252）はタイムアウト
  - k3s-worker の `tailscale status` は `Logged out.`（`state: NeedsLogin`）
  - tailscaled: `2026-10-11T12:32:37Z Switching ipn state Running -> NeedsLogin`、再起動後は `control: server reports new node key [eLTEW] has expired`
  - mc-gateway から見た peer: `k3s-worker KeyExpiry=2026-10-11T12:32:37Z Expired=True Tags=None`（mc-gateway 自身は `tag:k3s-worker` で `KeyExpiry=None`）
  - vmalert: `OnpremSilence` が 21:43 から firing。障害中の Discord 送信は 2 回・失敗 0

- **特定された原因**:
  - **直接原因**: k3s-worker の Tailscale ノードキーが 2026-10-11 21:32:37 JST に期限切れになり、GCE ↔ k3s の Tailscale 経路が切れた
  - **根本原因**: k3s-worker はタグなし（ユーザー所有）のデバイスとして対話ログインで参加しており、既定の有効期限 180 日が付いていた。その期限を記録・監視する仕組みも、無効化する手順もなかった
  - **検知が遅れた原因**: Bedrock のアラートの元データ（mc-monitor のメトリクス）が、切れたのと同じ Tailscale 経路で送られるため届かなかった。鳴ったのは汎用の `OnpremSilence` だけで、Bedrock に入れないこともノードキー失効であることも示さなかった

---

## 🛠️ 3. 対応内容

### 暫定対応（ワークアラウンド）

- [x] k3s-worker の再認証（tailscaled が出した認証 URL をユーザーが承認）。デバイスを削除せずに再認証したため、IP `100.107.122.45` は変わらず、GCE 側の socat の宛先を直す必要はなかった
- [x] BDS は正常だったため、Pod の再起動はしていない

### 恒久対応（根本修正）

- [x] Tailscale 管理画面で `k3s-worker-1` の key expiry を無効化（Machines → `⋯` → Disable key expiry）。再認証の直後は `KeyExpiry=2027-04-09T17:09:29Z`（新たに 180 日）だったが、無効化後は mc-gateway から見た peer の `KeyExpiry` が空（`None`）になったことを確認した

---

## 💡 4. 学び・改善点

- [ ] **監視の強化**: Tailscale の Webhook（`nodeKeyExpiringInOneDay` / `nodeKeyExpired`）を Discord に送り、ノードキーの失効前後に通知が来るようにする
- [ ] **監視の強化**: `OnpremSilence` の説明に一次切り分け（k3s-worker で `tailscale status` を見て、`NeedsLogin` ならノードキー失効）を書き、通知を見た時点で原因の見当がつくようにする
- [ ] **監視の強化**: Bedrock の到達性を mc-gateway 側からも測り、Tailscale が切れても「Bedrock に入れない」ことを直接通知できるようにする
- [ ] **プロセスの改善**: 障害対応などで Tailscale に対話ログインで参加させたら、その場で key expiry の無効化（またはタグ付け）まで済ませることを手順にする
- [ ] **自動化**: `Ansible/install_k3s.yml` の Tailscale 認証をタグ付き auth key に揃え、実機の設定（ホスト名・経路広告なし）と一致させる
- [ ] **別リスク（本件の原因ではない）**: BDS の `transport` 既定値が `nethernet` になっている。`transport=raknet` は PVC の server.properties にしかないため IaC に反映し、`:latest` による BDS 自動更新の扱い（バージョン固定）も検討する
- [ ] **別リスク（本件の原因ではない）**: vmagent の送信待ちデータを emptyDir に置く（`-remoteWrite.tmpDataPath=/tmp/vmagent-wal`）。今は障害中に vmagent が再起動すると送信待ちのデータが消える

---

*Created by: Claude Code（調査）/ @Tagomori0211*
