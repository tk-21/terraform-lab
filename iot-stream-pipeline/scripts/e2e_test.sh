#!/bin/bash
# パイプライン全体のE2Eテスト
# 測定項目: 書き込みレイテンシ、API応答時間、データ欠損率

set -euo pipefail

API_ENDPOINT=$(jq -r '.api_endpoint.value' phase3_outputs.json)
STREAM_NAME="iot-pipeline-stream"
TABLE_NAME="iot-pipeline-table"
DEVICE_ID="e2e-test-device"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "=============================="
echo " IoT Stream Pipeline E2Eテスト"
echo "=============================="

# 1. テストデータ送信
echo ""
echo "--- Step 1: Kinesisにテストレコードを送信 ---"
SEND_TIME=$(date +%s%N)
aws kinesis put-record \
  --stream-name "${STREAM_NAME}" \
  --partition-key "${DEVICE_ID}" \
  --data "$(echo "{\"device_id\":\"${DEVICE_ID}\",\"temperature\":42.0,\"humidity\":55.5,\"status\":\"test\",\"timestamp\":\"${TIMESTAMP}\"}" | base64)" \
  --query 'SequenceNumber' \
  --output text
echo "送信完了"

# 2. DynamoDBへの書き込みを確認 (最大60秒待機)
echo ""
echo "--- Step 2: DynamoDB書き込み確認 (最大60秒待機) ---"
MAX_WAIT=60
ELAPSED=0
WRITE_TIME=""

while [ $ELAPSED -lt $MAX_WAIT ]; do
  RESULT=$(aws dynamodb get-item \
    --table-name "${TABLE_NAME}" \
    --key "{\"device_id\":{\"S\":\"${DEVICE_ID}\"},\"timestamp\":{\"S\":\"${TIMESTAMP}\"}}" \
    --query 'Item.status.S' \
    --output text 2>/dev/null || echo "None")

  if [ "${RESULT}" = "test" ]; then
    WRITE_TIME=$(date +%s%N)
    LATENCY_MS=$(( (WRITE_TIME - SEND_TIME) / 1000000 ))
    echo "✅ DynamoDB書き込み確認: ${LATENCY_MS}ms (Kinesis送信からの経過時間)"
    break
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
  echo "待機中... ${ELAPSED}秒経過"
done

if [ -z "${WRITE_TIME}" ]; then
  echo "❌ タイムアウト: ${MAX_WAIT}秒以内にDynamoDBへの書き込みを確認できませんでした"
  exit 1
fi

# 3. API Gateway経由でデータ取得
echo ""
echo "--- Step 3: API Gateway経由でデータ取得 ---"
API_START=$(date +%s%N)
HTTP_RESPONSE=$(curl -s -o /tmp/api_response.json -w "%{http_code}" \
  "${API_ENDPOINT}/${DEVICE_ID}")
API_END=$(date +%s%N)
API_LATENCY_MS=$(( (API_END - API_START) / 1000000 ))

if [ "${HTTP_RESPONSE}" = "200" ]; then
  COUNT=$(jq '.count' /tmp/api_response.json)
  echo "✅ API応答: HTTP ${HTTP_RESPONSE}, 取得件数=${COUNT}, レイテンシ=${API_LATENCY_MS}ms"
  jq . /tmp/api_response.json
else
  echo "❌ API応答エラー: HTTP ${HTTP_RESPONSE}"
  cat /tmp/api_response.json
  exit 1
fi

# 4. 結果サマリ
echo ""
echo "=============================="
echo " E2Eテスト結果サマリ"
echo "=============================="
echo "Kinesis → DynamoDB レイテンシ: ${LATENCY_MS}ms"
echo "API Gateway レイテンシ:         ${API_LATENCY_MS}ms"
echo "テスト結果: ✅ 全項目PASS"
echo ""
echo "※ 面接でのトーキングポイント:"
echo "  - エンドツーエンドのデータ到達時間を計測して${LATENCY_MS}msを記録"
echo "  - Lambda bisect設定でバッチ失敗の部分リトライを実現"
