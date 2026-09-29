"""
GCP 課金アラート → Discord 通知スクリプト

mc-gateway 上の systemd サービス mc-discord-notifier として常駐し、5 分ごとに
Pub/Sub Pull サブスクリプション billing-alerts-gce-pull をポーリングする。
GCP Budget アラート（alertThresholdExceeded）を Discord に embed 通知して ACK する。
（オンプレ沈黙などメトリクス系アラートは vmalert + Alertmanager が担当する）

重複抑制: 同じしきい値(90%/100%)は当月内に1度だけ通知する。
          月初に月文字列が変わったら自動リセット。
          Discord 送信に成功した時点で通知済みとして記録し、失敗時は再配信で再試行する。

認証: GCE VM (mc-gateway) の mc-proxy-sa ADC（メタデータサーバー経由）
      → Pub/Sub subscriber + Secret Manager (webhook) アクセス権が必要（Terraform/notifications.tf）
"""
import base64
import json
import sys
import time
import urllib.request
from datetime import datetime, timezone, timedelta


PROJECT_ID   = "project-61cf5742-d0ea-45ed-ac0"
SUBSCRIPTION = f"projects/{PROJECT_ID}/subscriptions/billing-alerts-gce-pull"
SECRET_NAME  = "mc-discord-webhook-url"
# 5 分間隔ループ（compose の restart で常駐）
LOOP_INTERVAL = 300

# 当月通知済みしきい値マップ: {threshold_pct_int: "YYYY-MM"}（月初に月文字列が変わると自動リセット）
_notified_budget_thresholds: dict[int, str] = {}
JST = timezone(timedelta(hours=9))  # 日本標準時


def _current_month_key() -> str:
    """JST での現在の年月キー（"YYYY-MM"）を返す。月初リセット判定に使用。"""
    return datetime.now(JST).strftime("%Y-%m")


def _already_notified(threshold_pct: int) -> bool:
    """当月すでに通知済みのしきい値なら True。"""
    return _notified_budget_thresholds.get(threshold_pct) == _current_month_key()


def _mark_notified(threshold_pct: int) -> None:
    """Discord 送信成功後に、当月通知済みとして記録する。"""
    _notified_budget_thresholds[threshold_pct] = _current_month_key()


def _get_access_token() -> str:
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/"
        "instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())["access_token"]


def _get_webhook_url(token: str) -> str:
    url = (
        f"https://secretmanager.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/secrets/{SECRET_NAME}/versions/latest:access"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        payload_b64 = json.loads(resp.read())["payload"]["data"]
    return base64.b64decode(payload_b64).decode().strip()


def _pull_messages(token: str) -> list:
    url = f"https://pubsub.googleapis.com/v1/{SUBSCRIPTION}:pull"
    body = json.dumps({"maxMessages": 10}).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read()).get("receivedMessages", [])


def _ack_messages(token: str, ack_ids: list) -> None:
    url = f"https://pubsub.googleapis.com/v1/{SUBSCRIPTION}:acknowledge"
    body = json.dumps({"ackIds": ack_ids}).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        resp.read()


def _post_discord(webhook_url: str, embed: dict) -> None:
    payload = json.dumps({"embeds": [embed]}).encode()
    req = urllib.request.Request(
        webhook_url, data=payload,
        headers={
            "Content-Type": "application/json",
            # Cloudflare は Python-urllib を ASN レベルでブロックするため偽装が必要
            "User-Agent": "DiscordBot (https://github.com, 1.0)",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        resp.read()


def _budget_embed(data: dict) -> dict | None:
    """GCP Budget アラート embed を構築する。閾値超過なしなら None。"""
    threshold = float(data.get("alertThresholdExceeded", 0))
    if threshold == 0:
        return None

    cost     = float(data.get("costAmount", 0))
    budget   = float(data.get("budgetAmount", 0))
    name     = data.get("budgetDisplayName", "Minecraft Infrastructure")
    currency = data.get("currencyCode", "USD")
    project  = data.get("projectId", PROJECT_ID)

    pct     = int(round(threshold * 100))
    is_over = threshold >= 1.0
    color   = 0xE74C3C if is_over else 0xFF9F43
    icon    = "🚨" if is_over else "⚠️"

    ratio_str = f"{cost / budget * 100:.1f}%" if budget > 0 else "N/A"
    fmt = "{:,.0f}" if currency == "JPY" else "{:,.2f}"
    cost_str   = f"¥{fmt.format(cost)}"   if currency == "JPY" else f"{currency} {fmt.format(cost)}"
    budget_str = f"¥{fmt.format(budget)}" if currency == "JPY" else f"{currency} {fmt.format(budget)}"
    return {
        "title": f"{icon} GCP 課金アラート {pct}%",
        "description": (
            f"予算 **{name}** の **{pct}%** しきい値を超過しました。\n"
            f"現在の支出: **{cost_str}** / 予算上限: {budget_str}"
        ),
        "color": color,
        "fields": [
            {"name": "支出率",      "value": ratio_str, "inline": True},
            {"name": "プロジェクト", "value": project,   "inline": True},
        ],
    }


def _handle_message(webhook_url: str, data: dict) -> None:
    """課金アラートを Discord に通知する。通知不要なら何もしない（ACK は呼び出し側）。"""
    embed = _budget_embed(data)
    if embed is None:
        print("閾値超過なし: ACK のみ実行", flush=True)
        return

    # 重複抑制: 当月すでに通知済みのしきい値はスキップ
    threshold = float(data.get("alertThresholdExceeded", 0))
    threshold_pct = int(round(threshold * 100))
    if _already_notified(threshold_pct):
        print(
            f"課金アラート {threshold_pct}% は当月通知済みのためスキップ（ACK のみ実行）",
            flush=True,
        )
        return

    _post_discord(webhook_url, embed)
    # 送信成功後に記録する（送信失敗時は例外で ACK されず、再配信時に再送される）
    _mark_notified(threshold_pct)
    print(f"Discord 通知送信完了: 課金アラート {threshold_pct}%", flush=True)


def poll_once() -> None:
    token = _get_access_token()
    messages = _pull_messages(token)
    if not messages:
        print("メッセージなし", flush=True)
        return

    webhook_url = _get_webhook_url(token)
    ack_ids = []
    for msg in messages:
        ack_ids.append(msg["ackId"])
        try:
            raw  = base64.b64decode(msg["message"]["data"]).decode("utf-8")
            data = json.loads(raw)
            _handle_message(webhook_url, data)
        except Exception as e:
            print(f"通知失敗（ACK はスキップ）: {e}", flush=True)
            ack_ids.pop()  # 失敗メッセージはリトライさせる

    if ack_ids:
        _ack_messages(token, ack_ids)
        print(f"{len(ack_ids)} 件を ACK", flush=True)


def main() -> None:
    print(f"discord-notifier loop start (interval={LOOP_INTERVAL}s)", flush=True)
    while True:
        try:
            poll_once()
        except Exception as e:
            print(f"スクリプトエラー（継続）: {e}", flush=True, file=sys.stderr)
        time.sleep(LOOP_INTERVAL)


if __name__ == "__main__":
    main()
