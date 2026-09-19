#!/usr/bin/env bash
# Chatwork通知スクリプト
# Operatorのブートストラップ完了をChatworkルームに通知する疎通確認用
# 本番ではOperator本体のGo実装(internal/notify/)がこのロジックを内包する
#
# 使い方:
#   export AWS_REGION=ap-northeast-1
#   ./scripts/notify-chatwork.sh "Operator Phase 1 完了"
#
# 前提: aws cli, jq がインストール済みであること
# SSM Parameter Storeに以下が設定済みであること:
#   /gpu-inference-operator-lab/chatwork-token
#   /gpu-inference-operator-lab/chatwork-room-id

set -euo pipefail

MESSAGE="${1:-"[GPU Inference Operator] ブートストラップ完了"}"
REGION="${AWS_REGION:-ap-northeast-1}"

# SSM Parameter Storeからシークレットを取得する
# ハードコード禁止ポリシーへの対応: スクリプト内にトークンを書かない
echo "SSM Parameter StoreからChatwork認証情報を取得中..."

CHATWORK_TOKEN=$(aws ssm get-parameter \
  --name "/gpu-inference-operator-lab/chatwork-token" \
  --with-decryption \
  --region "${REGION}" \
  --query "Parameter.Value" \
  --output text)

ROOM_ID=$(aws ssm get-parameter \
  --name "/gpu-inference-operator-lab/chatwork-room-id" \
  --region "${REGION}" \
  --query "Parameter.Value" \
  --output text)

if [[ "${CHATWORK_TOKEN}" == "PLACEHOLDER_SET_MANUALLY" ]] || [[ "${ROOM_ID}" == "PLACEHOLDER_SET_MANUALLY" ]]; then
  echo "ERROR: SSM Parameterの値が初期値のままです。以下のコマンドで設定してください:"
  echo "  aws ssm put-parameter --name '/gpu-inference-operator-lab/chatwork-token' \\"
  echo "    --value '<your-token>' --type SecureString --overwrite --region ${REGION}"
  echo "  aws ssm put-parameter --name '/gpu-inference-operator-lab/chatwork-room-id' \\"
  echo "    --value '<your-room-id>' --type String --overwrite --region ${REGION}"
  exit 1
fi

# Chatwork API v2 POST /rooms/{room_id}/messages
# ヘッダー: X-ChatWorkToken, Content-Type: application/x-www-form-urlencoded
RESPONSE=$(curl -s -o /tmp/chatwork_response.json -w "%{http_code}" \
  -X POST \
  -H "X-ChatWorkToken: ${CHATWORK_TOKEN}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "body=${MESSAGE}" \
  "https://api.chatwork.com/v2/rooms/${ROOM_ID}/messages")

HTTP_STATUS="${RESPONSE}"

if [[ "${HTTP_STATUS}" == "200" ]]; then
  MESSAGE_ID=$(jq -r '.message_id' /tmp/chatwork_response.json)
  echo "通知成功 (message_id: ${MESSAGE_ID})"
else
  echo "ERROR: Chatwork APIがエラーを返しました (HTTP ${HTTP_STATUS})"
  cat /tmp/chatwork_response.json
  exit 1
fi
