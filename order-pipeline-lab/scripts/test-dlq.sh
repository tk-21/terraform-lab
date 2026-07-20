#!/bin/bash
# DLQ テスト: 意図的に壊れたメッセージを投入し DLQ 動作を確認する
set -euo pipefail

REGION="ap-northeast-1"
QUEUE_URL=$(cd terraform && terraform output -raw orders_queue_url)

echo "=== DLQ テスト: 不正メッセージを投入 ==="
echo "order_id なしのメッセージを投入 → sfn-trigger Lambda がエラー"
echo "→ SQS が maxReceiveCount(3) 超過後に DLQ へ転送"
echo ""

for i in $(seq 1 3); do
  aws sqs send-message \
    --queue-url "${QUEUE_URL}" \
    --message-body '{"amount": 1000, "items": []}' \
    --region "${REGION}"
  echo "  不正メッセージ ${i}/3 を投入"
  sleep 2
done

echo ""
echo "3分後に DLQ を確認してください:"
echo "  aws sqs get-queue-attributes \\"
DLQ_URL=$(cd terraform && terraform output -raw orders_dlq_url 2>/dev/null || echo "")
if [ -n "${DLQ_URL}" ]; then
  echo "    --queue-url ${DLQ_URL} \\"
fi
echo "    --attribute-names All --region ${REGION}"
