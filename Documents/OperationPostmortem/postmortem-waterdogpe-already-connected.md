# 📝 インシデント・ポストモーテム

> **概要**
> このドキュメントは発生した事象を客観的に記録し、再発防止に繋げるためのものです。
> 犯人探しではなく、システムとプロセスの改善（Blameless Postmortem）を目的とします。

---

## 📅 基本情報

| 項目 | 内容 |
|------|------|
| 発生日時 | 2026-03-20 06:42 (JST) |
| 解消日時 | 2026-03-20 07:34 (JST) (所要時間: 約52分) |
| 影響範囲 | Bedrock版サーバー: 複数人が同時接続できない。2人目以降の接続が `Already connected` エラーで拒否される |
| 対応者 | @Tagomori0211 / Antigravity AI |

---

## 🔍 1. 何が起きたか（状況）

- **事象概要**:
  - Bedrock版クライアントが WaterdogPE プロキシ (GKE) 経由でオンプレミス Bedrock サーバー (`bedrock-survival`) に接続する際、`Connection to bedrock-survival failed: Already connected` エラーが発生。1人目の接続は成功するが、2人目以降が接続できない、または再接続時にエラーとなる状態。

- **タイムライン**:
  - `06:42`: ユーザー `Potato sub9183` が接続試行 → `Already connected` エラー発生をログで確認
  - `06:42~06:50`: 同ユーザーが複数回リトライするも断続的にエラーが発生
  - `07:09`: ユーザー `Time 7459` が接続 → 単独では接続成功
  - `07:29`: 運営より「複数人接続不可」の障害報告
  - `07:30`: 初動調査開始 ― WaterdogPE ログの精査と WaterdogPE の仕様調査
  - `07:33`: 原因特定 ― ConfigMap の設定不備 (3項目) を修正し、Pod 再デプロイ
  - `07:34`: WaterdogPE 正常起動を確認、復旧

---

## 🔬 2. 調査プロセス

### 実行コマンド

```bash
# WaterdogPE のログ確認 (GKE)
kubectl logs deployment/waterdogpe -n minecraft --tail=100

# WaterdogPE の設定ファイル確認
cat k8s/gke/waterdogpe-configmap.yaml

# Pod の状態確認
kubectl get pods -A | grep waterdog
```

- **確認したログの内容**:
  ```
  06:42:46 [INFO ] [/133.209.10.160:24677|Potato sub9183] -> Upstream has disconnected:
    Connection to bedrock-survival failed: Already connected

  06:42:56 [ERROR] [/133.209.10.160:24677|Potato sub9183] Unable to connect to downstream bedrock-survival
  io.netty.channel.ChannelException: Already connected
      at org.cloudburstmc.netty.handler.codec.raknet.client.RakClientOfflineHandler.channelRead0(...)
  ```
  - RakNet クライアント層 (`RakClientOfflineHandler`) で「既に接続済み」と判定されている
  - 前回のセッションが正しくクリーンアップされずに残存（ゴーストセッション）

- **特定された原因**:
  1. **`use_login_extras: true`** ― BDS (vanilla Bedrock Dedicated Server) は WaterdogPE 独自の `Waterdog_XUID` 等のカスタムログインフィールドを理解しない。ログイン処理で不整合が生じ、セッション確立が不完全な状態になっていた
  2. **`prefer_fast_transfer: true`** ― サーバー転送時にセッションを完全切断せず再利用する設計だが、単一サーバー構成では前セッションが残ったまま新接続を開始するため RakNet 層で競合が発生
  3. **`inject_proxy_to_server_handshake` 未設定** ― プロキシ→サーバー間のハンドシェイクにプレイヤー識別情報が注入されず、下流サーバーが接続元を正しく区別できていなかった
  4. **WaterdogPE 既知バグ (GitHub Issue #320)** ― 暗号化有効時、クライアントがタイムアウトすると `PlayerDisconnectedEvent` が発火せず、プレイヤーリストにゴーストが残る問題

---

## 🛠️ 3. 対応内容

### 暫定対応（ワークアラウンド）

- [x] WaterdogPE Pod の再起動によるゴーストセッションのクリア

### 恒久対応（根本修正）

- [x] `waterdogpe-configmap.yaml` の設定変更:
  ```diff
  - use_login_extras: true
  + use_login_extras: false
  + inject_proxy_to_server_handshake: true
  - prefer_fast_transfer: true
  + prefer_fast_transfer: false
  ```
- [x] GKE 上の ConfigMap 適用 & Pod 再デプロイ (`kubectl apply` + `kubectl rollout restart`)
- [x] GitHub への変更 Push (commit: `df1400f`)

---

## 💡 4. 学び・改善点

- [ ] **監視の強化**: WaterdogPE の接続エラー率を Prometheus メトリクスで収集し、`Already connected` エラーの閾値アラートを設定する
- [ ] **プロセスの改善**: プロキシソフトウェア (WaterdogPE) の設定変更時、下流サーバーの種別 (BDS / PocketMine / Nukkit) との互換性を事前にチェックリストで確認する
- [ ] **ナレッジの蓄積**: WaterdogPE の各設定項目の意味と BDS との互換性マトリクスをドキュメント化する
- [ ] **自動化**: WaterdogPE の設定変更後に自動で複数人接続テストを実行する仕組みの検討

---

## 🚨 追加のインシデント（続報）：Node.js bedrock-relay でのパケット喪失とXUID消失

### 📅 基本情報
| 項目 | 内容 |
|------|------|
| 発生日時 | 2026-03-23 00:36 (JST) 頃以降 |
| 解消日時 | 2026-03-23 03:40 (JST) |
| 影響範囲 | Bedrock版サーバー: サーバーにログインできるが、チェストやドアが開かない。また、複数人がログインするとログイン衝突（XUID: Unknown）が発生し、2人目以降が弾かれる |
| 対応者 | @Tagomori0211 / Antigravity AI |

### 🔍 1. 何が起きたか（状況）
- **事象概要**:
  - 前回のWaterdogPE（OOMやゴーストセッション問題）を回避するため、Node.jsベースの `bedrock-relay`（`bedrock-protocol`ライブラリ使用）へ刷新・移行した。
  - プロキシ変更後、以下の致命的な問題が連続して発生した。
    1. **接続確立の失敗・タイムアウト**: NginxのUDPプロキシ設定に誤りがあり、クライアントが数秒で切断される。
    2. **パケット喪失（チェストが開かない等）**: `bedrock-relay`（v1.26.0相当）と、バックエンドBDS（v1.26.3.1）の間にプロトコルバージョンの不一致があり、操作パケットがプロキシ層でドロップ（破棄）される。
    3. **複数人接続不可（XUID消失）**: プロキシが `offline: true` で動作していたため、クライアントから送信されたXbox Live認証の暗号化ペイロードをプロキシが剥がし、全プレイヤーのXUIDが `Unknown (0)` としてBDSに転送されてしまい、再びID衝突が発生。

### 🔬 2. 調査プロセス
- **Nginx設定の調査**:
  - `k8s/gke/20-nginx-gw.yaml` にて、UDPサーバー設定に `proxy_responses 1;` が混入していたことを発見。
  - これにより、「サーバーから1つ応答が返ってきた瞬間にNginxがUDPセッションを強制切断する」状態になっており、ストリーミング通信が維持できず、後続の接続要求が新しいUDPポートから送信されてしまいRakNetのハンドシェイクが破綻していた。
- **XUID消失・パケット喪失の調査**:
  - `kubectl logs` でBDSのログを確認したところ、プレイヤーが `xuid: 0` でログインしていることを確認。
  - L7プロキシ（`bedrock-protocol`）がすべてのパケットを展開・解析して再構築する仕様のため、「認証トークンの破棄」および「マイナーバージョン違いによる未知のインタラクションパケットの破棄」が避けられない構造的限界に直面していると判断。

### 🛠️ 3. 対応内容（抜本的解決）
**「L7プロキシ（Node.jsベース）の完全撤廃と、L4（UDP透過）ルーターの直結」**
- [x] **Nginx設定の修正**: `proxy_responses 1;` を削除し、`proxy_timeout 10m;` とすることで継続的なUDPストリームを維持。
- [x] **プロキシの廃止とhostPort転送**: Node.jsのプロキシサービス（`bedrock-relay`）を完全に破棄・停止。
- [x] **Kubernetes NativeなUDP転送の採用**: `ubuntu-151`上のBDSコンテナ（`deploy-bedrock`）に `hostPort: 19132` を付与。GKE（Nginx）からのUDPパケットを、パケットを解析・改変することなく100%透過的にBDSコンテナへ流し込むようにアーキテクチャを変更。
- [x] **リソース最適化**: TPS低下を防ぐため、BDS PodのCPU Limits/Requestsをホスト上限に合わせてチューニング。

### 💡 4. 学び・改善点
- **L7とL4プロキシの使い分け**: 認証やバージョン管理が厳格なゲームサーバー（特に最新版が強制されるBedrock版）において、単一サーバーへの単純転送目的で安易にL7プロキシを間に挟むと、「トークン剥がれ」や「パケット翻訳エラー」の温床となる。
- 単純なルーティング目的であれば、L4のパケット透過プロキシ（Nginx Stream UDP + K8s hostPort / NodePort）を利用するのが最もロスがなく、完全なプロトコル互換性（XUID等を含む）を担保できることが実証された。

---

*Updated by: Antigravity AI*
