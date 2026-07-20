#!/bin/bash
# 障害耐性テスト: 大量注文を投入し DLQ・リトライ動作を確認する
set -euo pipefail

REGION="ap-northeast-1"
QUEUE_URL=$(cd terraform && terraform output -raw orders_queue_url)
STATE_MACHINE_ARN=$(cd terraform && terraform output -raw state_machine_arn)
TABLE_NAME="order-pipeline-orders"

echo "=== 障害耐性テスト開始 ==="
echo "注文 20件を連続投入します..."

SUCCESS=0
for i in $(seq 1 20); do
  ORDER_ID="chaos-$(date +%s)-${i}"
  AMOUNT=$((RANDOM % 10000 + 1000))

  aws sqs send-message \
    --queue-url "${QUEUE_URL}" \
    --message-body "{
      \"order_id\": \"${ORDER_ID}\",
      \"amount\": ${AMOUNT},
      \"items\": [{\"sku\": \"SKU-$(( RANDOM % 5 + 1 ))\", \"qty\": $(( RANDOM % 3 + 1 ))}]
    }" \
    --region "${REGION}" > /dev/null

  SUCCESS=$((SUCCESS + 1))
  echo "  投入: ${ORDER_ID} (amount=${AMOUNT})"
  sleep 0.5  # レートリミット回避
done

echo ""
echo "=== 投入完了: ${SUCCESS}件 ==="
echo "30秒後に結果を集計します..."
sleep 30

echo ""
echo "=== Step Functions 実行結果 ==="
aws stepfunctions list-executions \
  --state-machine-arn "${STATE_MACHINE_ARN}" \
  --region "${REGION}" \
  --max-results 25 \
  | jq -r '
    .executions |
    group_by(.status) |
    map({status: .[0].status, count: length}) |
    .[] | "\(.status): \(.count)件"
  '

echo ""
echo "=== DLQ メッセージ数 ==="
DLQ_URL=$(cd terraform && terraform output -raw orders_dlq_url 2>/dev/null || echo "")
if [ -n "${DLQ_URL}" ]; then
  aws sqs get-queue-attributes \
    --queue-url "${DLQ_URL}" \
    --attribute-names ApproximateNumberOfMessages \
    --region "${REGION}" \
    | jq -r '.Attributes.ApproximateNumberOfMessages + " 件が DLQ に到達"'
fi

echo ""
echo "=== DynamoDB ステータス集計 ==="
# なぜ: scan は本番禁止だがテスト目的に限り使用する
aws dynamodb scan \
  --table-name "${TABLE_NAME}" \
  --filter-expression "begins_with(order_id, :prefix)" \
  --expression-attribute-values '{":prefix": {"S": "chaos-"}}' \
  --region "${REGION}" \
  | jq -r '
    .Items |
    group_by(.status.S) |
    map({status: .[0].status.S, count: length}) |
    .[] | "\(.status): \(.count)件"
  '

echo ""
echo "=== テスト完了 ==="
echo "CloudWatch ダッシュボードで詳細を確認してください:"
cd terraform && terraform output -raw dashboard_url
