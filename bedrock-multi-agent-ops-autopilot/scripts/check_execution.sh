#\!/bin/bash
set -e

EXECUTION_NAME=$1
REGION="ap-northeast-1"

if [ -z "$EXECUTION_NAME" ]; then
  echo "使用方法: $0 <execution_name>"
  exit 1
fi

echo "=== 実行結果確認: ${EXECUTION_NAME} ==="

# DynamoDB確認
echo "--- DynamoDB実行履歴 ---"
aws dynamodb get-item \
  --table-name bmao-execution-history \
  --key "{\"execution_id\": {\"S\": \"${EXECUTION_NAME}\"}}" \
  --region $REGION \
  --output table 2>/dev/null || echo "レコードが見つかりません"

# S3レポート確認
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "--- S3レポート一覧 ---"
aws s3 ls "s3://bmao-reports-${ACCOUNT_ID}/" \
  --region $REGION \
  --recursive \
  --human-readable \
  --summarize 2>/dev/null || echo "S3バケットが見つかりません"

echo "=== 確認完了 ==="
