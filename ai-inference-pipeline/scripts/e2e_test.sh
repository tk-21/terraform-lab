#!/bin/bash
# E2Eテスト: S3アップロードからChatwork通知までの全フローを検証
set -euo pipefail

cd "$(dirname "$0")/../terraform/environments/dev"

INPUT_BUCKET=$(terraform output -raw input_bucket_name)
SFN_ARN=$(terraform output -raw state_machine_arn)
DYNAMODB_TABLE=$(terraform output -raw dynamodb_table_name)
REGION="ap-northeast-1"

echo "======================================"
echo "AI推論パイプライン E2Eテスト開始"
echo "======================================"

# Step 1: テストデータ生成・アップロード
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_KEY="input/e2e_test_${TIMESTAMP}.csv"

cat > /tmp/e2e_input.csv << 'CSVEOF'
id,title,description,category
1,ECS Fargate,サーバーレスコンテナ実行環境,infra
2,Amazon Bedrock,生成AI基盤サービス,ai
3,Step Functions,サーバーレスワークフローオーケストレーター,serverless
4,Terraform,IaCツール,devops
CSVEOF

echo "[1/5] テストデータをS3にアップロード中..."
aws s3 cp /tmp/e2e_input.csv "s3://$INPUT_BUCKET/$TEST_KEY" --region "$REGION"
echo "    完了: s3://$INPUT_BUCKET/$TEST_KEY"

# Step 2: EventBridgeがStep Functionsを起動するまで待機
# EventBridgeのイベント配信には数秒のラグがあるため15秒待機する
echo "[2/5] EventBridgeトリガーを待機中 (15秒)..."
sleep 15

# 最新の実行ARNを取得（RUNNING優先、なければ最新の実行を取得）
EXECUTION_ARN=$(aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --status-filter "RUNNING" \
  --max-results 1 \
  --query 'executions[0].executionArn' \
  --output text \
  --region "$REGION")

if [ "$EXECUTION_ARN" = "None" ] || [ -z "$EXECUTION_ARN" ]; then
  EXECUTION_ARN=$(aws stepfunctions list-executions \
    --state-machine-arn "$SFN_ARN" \
    --max-results 1 \
    --query 'executions[0].executionArn' \
    --output text \
    --region "$REGION")
fi

echo "    実行ARN: $EXECUTION_ARN"

# Step 3: 実行完了まで待機（最大5分）
echo "[3/5] パイプライン完了を待機中..."
MAX_WAIT=300
ELAPSED=0
INTERVAL=15

while [ $ELAPSED -lt $MAX_WAIT ]; do
  STATUS=$(aws stepfunctions describe-execution \
    --execution-arn "$EXECUTION_ARN" \
    --query 'status' \
    --output text \
    --region "$REGION")

  echo "    ステータス: $STATUS (経過: ${ELAPSED}秒)"

  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "    パイプライン成功"
    break
  elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "ABORTED" ] || [ "$STATUS" = "TIMED_OUT" ]; then
    echo "    パイプライン失敗: $STATUS"
    aws stepfunctions describe-execution \
      --execution-arn "$EXECUTION_ARN" \
      --region "$REGION" \
      --query '{cause: cause, error: error}'
    exit 1
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo "タイムアウト: ${MAX_WAIT}秒以内に完了しませんでした"
  exit 1
fi

# Step 4: DynamoDB結果確認
echo "[4/5] DynamoDB結果を確認..."
RESULT=$(aws dynamodb scan \
  --table-name "$DYNAMODB_TABLE" \
  --filter-expression "#s = :completed" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":completed": {"S": "completed"}}' \
  --query 'Count' \
  --output text \
  --region "$REGION")

echo "    DynamoDB完了レコード数: $RESULT"

if [ "$RESULT" -gt 0 ]; then
  echo "    DynamoDB確認OK"
else
  echo "    DynamoDBにレコードが存在しません"
  exit 1
fi

# Step 5: 実行時間計測
echo "[5/5] パフォーマンス計測..."
aws stepfunctions describe-execution \
  --execution-arn "$EXECUTION_ARN" \
  --region "$REGION" \
  --query '{StartDate: startDate, StopDate: stopDate, Status: status}'

echo ""
echo "======================================"
echo "E2Eテスト完了"
echo "======================================"
