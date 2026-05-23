#!/bin/bash
# リソース全削除スクリプト（ハンズオン終了後のコスト削減用）
set -euo pipefail

echo "⚠️  全AWSリソースを削除します。5秒後に開始します..."
sleep 5

cd "$(dirname "$0")/../terraform/environments/dev"

# ECRのイメージを先に削除（Terraformのdestroy前に必要）
ECR_REPO=$(terraform output -raw ecr_repository_url 2>/dev/null | sed 's|.*/||')
if [ -n "$ECR_REPO" ]; then
  echo "ECRイメージを削除中..."
  aws ecr batch-delete-image \
    --repository-name "aip/dev/preprocessor" \
    --image-ids "$(aws ecr list-images --repository-name "aip/dev/preprocessor" \
      --query 'imageIds' --output json 2>/dev/null || echo '[]')" \
    --region ap-northeast-1 2>/dev/null || true
fi

# SSMパラメータ削除
echo "SSMパラメータを削除中..."
aws ssm delete-parameter --name "/aip/dev/chatwork/token" --region ap-northeast-1 2>/dev/null || true

# Terraform destroy
echo "Terraformリソースを削除中..."
terraform destroy -auto-approve

echo "✅ クリーンアップ完了"
