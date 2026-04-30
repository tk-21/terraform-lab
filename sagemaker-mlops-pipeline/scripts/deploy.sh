#!/bin/bash
set -euo pipefail

REGION="ap-northeast-1"
PREFIX="smp"

echo "========================================="
echo "SageMaker MLOps Pipeline デプロイ開始"
echo "========================================="

# Step 1: Terraform Apply（モジュール依存順に段階適用）
echo "[1/6] Terraform Apply - foundation"
cd terraform
terraform apply -target=module.foundation -var="environment=dev" -auto-approve

echo "[2/6] Terraform Apply - pipeline"
terraform apply -target=module.pipeline -var="environment=dev" -auto-approve

echo "[3/6] Terraform Apply - registry + endpoint"
terraform apply -target=module.registry -target=module.endpoint -var="environment=dev" -auto-approve

echo "[4/6] Terraform Apply - monitor"
terraform apply -target=module.monitor -var="environment=dev" -auto-approve

echo "[5/6] Terraform Apply - 残りリソース"
terraform apply -var="environment=dev" -auto-approve

cd ..

# Step 2: SSMパラメータ確認
echo "[6/6] SSMパラメータ確認"
ROOM_ID=$(aws ssm get-parameter --name "/smp/chatwork/room_id" \
  --query 'Parameter.Value' --output text --region "$REGION" 2>/dev/null || echo "REPLACE_ME")

if [ "$ROOM_ID" = "REPLACE_ME" ]; then
  echo ""
  echo "Chatworkパラメータを設定してください:"
  echo "  aws ssm put-parameter --name /smp/chatwork/room_id --value YOUR_ROOM_ID --type SecureString --overwrite --region $REGION"
  echo "  aws ssm put-parameter --name /smp/chatwork/api_token --value YOUR_TOKEN --type SecureString --overwrite --region $REGION"
fi

echo ""
echo "デプロイ完了"
echo "次のステップ: bash scripts/run_pipeline.sh"
