#!/bin/bash

# ==============================================================================
# Script: BDS_say.sh
# Description: Bedrock Dedicated Server (BDS) のコンソールに say コマンドを送信する
# Usage: ./BDS_say.sh "<message>"
# Example: ./BDS_say.sh "まもなくメンテナンスを開始します"
# ==============================================================================

# 引数チェック
if [ -z "$1" ]; then
  echo "Usage: $0 <message>"
  echo "Example: $0 \"まもなくメンテナンスを開始します\""
  exit 1
fi

MESSAGE="$1"
NAMESPACE="minecraft"

echo "🔎 Bedrock Podを検索中..."

# Label `app.kubernetes.io/component=bedrock` を用いてPodを特定
POD_NAME=$(ssh k3s-worker "sudo kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=bedrock -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null)

if [ -z "$POD_NAME" ]; then
  echo "❌ エラー: BedrockのPodが見つかりませんでした。"
  exit 1
fi

echo "✅ Bedrock Podを特定しました: ${POD_NAME} (Namespace: ${NAMESPACE})"
echo "💬 メッセージを送信中: ${MESSAGE}"

# リモートシェルで展開・分割されないよう、say コマンド全体を 1 引数としてエスケープして渡す
# （" や $ を含むメッセージでも文字列のまま BDS コンソールに届く）
REMOTE_ARG=$(printf '%q' "say ${MESSAGE}")

if ssh k3s-worker "sudo kubectl exec -n ${NAMESPACE} ${POD_NAME} -c bedrock -- send-command ${REMOTE_ARG}"; then
  echo "🚀 送信完了!"
else
  echo "⚠️ 送信に失敗しました。"
  exit 1
fi
