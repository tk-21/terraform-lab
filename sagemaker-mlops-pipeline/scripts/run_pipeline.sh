#!/bin/bash
set -euo pipefail

REGION="ap-northeast-1"
PREFIX="smp"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ARTIFACTS_BUCKET="${PREFIX}-artifacts-${ACCOUNT_ID}"
DATA_BUCKET="${PREFIX}-data-${ACCOUNT_ID}"
PIPELINE_ROLE_ARN=$(terraform -chdir=terraform output -raw pipeline_role_arn)

echo "========================================="
echo "MLOps パイプライン E2Eテスト"
echo "========================================="

# Step 1: サンプルデータ生成・アップロード
echo "[1/4] サンプルデータ生成"
python scripts/generate_sample_data.py \
  --bucket "$DATA_BUCKET" \
  --n-samples 1000

# Step 2: Pipeline定義をAWSにアップロード
echo "[2/4] Pipeline定義をAWSにアップロード"
python pipeline/pipeline_definition.py \
  --action upsert \
  --role-arn "$PIPELINE_ROLE_ARN" \
  --artifacts-bucket "$ARTIFACTS_BUCKET" \
  --data-bucket "$DATA_BUCKET"

# Step 3: Pipeline実行
echo "[3/4] パイプライン実行開始"
EXECUTION_ARN=$(aws sagemaker start-pipeline-execution \
  --pipeline-name "${PREFIX}-training-pipeline" \
  --pipeline-execution-display-name "e2e-test-$(date +%Y%m%d%H%M%S)" \
  --region "$REGION" \
  --query 'PipelineExecutionArn' \
  --output text)

echo "実行ARN: $EXECUTION_ARN"

# Step 4: 完了待機（最大30分、30秒間隔で60回ポーリング）
echo "[4/4] パイプライン完了を待機中..."
for i in $(seq 1 60); do
  STATUS=$(aws sagemaker describe-pipeline-execution \
    --pipeline-execution-arn "$EXECUTION_ARN" \
    --region "$REGION" \
    --query 'PipelineExecutionStatus' \
    --output text)

  echo "  [$i/60] Status: $STATUS"

  if [ "$STATUS" = "Succeeded" ]; then
    echo "パイプライン完了: $STATUS"
    break
  elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Stopped" ]; then
    echo "パイプライン失敗: $STATUS"
    exit 1
  fi

  sleep 30
done

echo ""
echo "次のステップ:"
echo "  1. Model Registryで新モデルを確認"
echo "  2. Chatworkで承認依頼通知を確認"
echo "  3. 承認コマンドを実行してデプロイをトリガー:"
echo "     aws sagemaker update-model-package \\"
echo "       --model-package-arn <MODEL_PACKAGE_ARN> \\"
echo "       --model-approval-status Approved"
