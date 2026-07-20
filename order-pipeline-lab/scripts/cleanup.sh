#!/bin/bash
# 全リソースを削除してコストをゼロにする
set -euo pipefail

echo "=== リソース削除開始 ==="
echo "WARNING: すべての AWS リソースが削除されます"
read -p "続行しますか？ (yes/no): " CONFIRM

if [ "${CONFIRM}" != "yes" ]; then
  echo "キャンセルしました"
  exit 0
fi

REGION="ap-northeast-1"

# なぜ: ECR リポジトリに画像が残っていると terraform destroy が失敗するため先に削除する
echo "ECR イメージを削除中..."
IMAGE_IDS=$(aws ecr list-images \
  --repository-name "order-pipeline/payment-processor" \
  --region "${REGION}" \
  --query 'imageIds[*]' \
  --output json 2>/dev/null || echo "[]")

if [ "${IMAGE_IDS}" != "[]" ] && [ -n "${IMAGE_IDS}" ]; then
  aws ecr batch-delete-image \
    --repository-name "order-pipeline/payment-processor" \
    --image-ids "${IMAGE_IDS}" \
    --region "${REGION}" > /dev/null
  echo "  ECR イメージを削除しました"
else
  echo "  削除対象の ECR イメージなし"
fi

echo "Terraform destroy を実行中..."
cd terraform
terraform destroy -auto-approve

echo ""
echo "=== クリーンアップ完了 ==="
