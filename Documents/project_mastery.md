# Project Mastery: Minecraft Hybrid Cloud Infrastructure

> **現行構成（README が正）**: 入口は **GCE**、VPN は **Tailscale**、ゲーム本体は **オンプレ k3s**。

## 1. トラフィックフローの完全把握

### Java版 Minecraft
1. **入口**: GCE `mc-gateway` の systemd `mc-socat-java`（TCP **25565**）
2. **VPN通過**: GCE の `tailscaled`（`gce-mc-gateway`）→ Tailscale トンネル
3. **バックエンド**: オンプレ k3s（namespace `minecraft`）の **Survival**（例: Node/Service **30065**、NeoForge 等。2026-09-30〜休眠中）
4. **転送先**: GCE socat は Tailscale IP 上のオンプレ側ポートへ fork（例: `100.x.x.x:30065`）

### Bedrock版 Minecraft
1. **入口**: GCE `mc-gateway` の systemd `mc-socat-bedrock`（UDP **19132**）
2. **VPN通過**: 同上 Tailscale
3. **バックエンド**: オンプレ k3s の **Bedrock (BDS)**（hostPort / Service **19132**）

## 2. インフラ・ネットワーク構成の詳細

### Tailscale 接続トポロジ
- **GCE側**: VM 上の `tailscaled`（systemd）。公開ゲームポートは GCE の socat が受け、以降は Tailscale 内へ。
- **オンプレ側**: k3s ワーカー等の host `tailscaled`（例: `k3s-worker-1`）。ゲーム Pod / NodePort へ到達。
- **名前解決**: Tailscale MagicDNS または Tailscale IP 直接指定。

### リソース割り当て（オンプレ Ryzen 5700G / 64Gi 目安・README 準拠）
- **Survival**: 約 30Gi RAM
- **Bedrock**: 約 8Gi RAM

### クラウド側（現行）
- **GCE `mc-gateway`**: e2-micro の単体 VM。socat（Java TCP / Bedrock UDP）+ Tailscale に加え、監視スタックと Status Platform も同居する。
- **監視など**: 同じ `mc-gateway` 上の VictoriaMetrics / Grafana 等（`gce/gateway/`）。本 mastery はゲーム経路に集中する。

## 3. 運用・保守の指針
- **デプロイ**: マニフェストは `k8s/` 以下で管理。命名規則（kebab-case, namespace prefix）を厳守。
- **同期**: 作業後は必ず `git commit` + `git push` を行う（本ファイル単独編集の任務では、命令がない限り commit しない）。
- **トラブル対応**: `Documents/OperationPostmortem/` に記録を残す。
- **権威**: アーキテクチャの一次情報はリポ直下 **README.md**。本ファイルと食い違う場合は README を優先し、本ファイルを追随させる。
