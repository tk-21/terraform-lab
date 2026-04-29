#\!/bin/bash
set -e

PREFIX="bmao"
REGION="ap-northeast-1"

echo "=== デプロイ確認スクリプト ==="

# Lambda関数の存在確認
for fn in incident-investigator cost-optimizer remediation reporter; do
  STATUS=$(aws lambda get-function --function-name "${PREFIX}-${fn}" \
    --region $REGION --query 'Configuration.State' --output text 2>/dev/null || echo "NOT_FOUND")
  echo "Lambda ${PREFIX}-${fn}: ${STATUS}"
done

# Bedrock Agent確認
echo "Bedrock Agents:"
aws bedrock-agent list-agents --region $REGION \
  --query 'agentSummaries[?contains(agentName, `bmao`)].{Name:agentName,Status:agentStatus}' \
  --output table

# DynamoDBテーブル確認
for tbl in execution-history approval-requests; do
  STATUS=$(aws dynamodb describe-table --table-name "${PREFIX}-${tbl}" \
    --region $REGION --query 'Table.TableStatus' --output text 2>/dev/null || echo "NOT_FOUND")
  echo "DynamoDB ${PREFIX}-${tbl}: ${STATUS}"
done

# Step Functions確認
SFN_ARN=$(aws stepfunctions list-state-machines --region $REGION \
  --query "stateMachines[?contains(name, '${PREFIX}')].stateMachineArn" \
  --output text)
echo "Step Functions: ${SFN_ARN}"

# S3バケット確認
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="bmao-reports-${ACCOUNT_ID}"
STATUS=$(aws s3api head-bucket --bucket "$BUCKET" --region $REGION 2>/dev/null && echo "EXISTS" || echo "NOT_FOUND")
echo "S3 ${BUCKET}: ${STATUS}"

# SSMパラメータ確認
for param in /bmao/chatwork/room_id /bmao/chatwork/api_token; do
  STATUS=$(aws ssm get-parameter --name "$param" --region $REGION \
    --query 'Parameter.Name' --output text 2>/dev/null || echo "NOT_FOUND")
  echo "SSM ${param}: ${STATUS}"
done

echo "=== 確認完了 ==="
