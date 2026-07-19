#!/usr/bin/env bash
# Terraformバックエンド用S3バケットとDynamoDBテーブルを作成するスクリプト。
# terraform init より前に一度だけ実行すること。
set -euo pipefail

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-northeast-1"
BUCKET_NAME="csar-tfstate-${AWS_ACCOUNT_ID}"
DYNAMODB_TABLE="csar-tfstate-lock"

echo "=== Terraformバックエンド初期化 ==="
echo "AWSアカウントID: ${AWS_ACCOUNT_ID}"
echo "バケット名: ${BUCKET_NAME}"
echo "DynamoDBテーブル: ${DYNAMODB_TABLE}"
echo ""

# S3バケット作成（東京リージョンはLocationConstraint必須）
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "[SKIP] S3バケット ${BUCKET_NAME} は既に存在します"
else
  echo "[CREATE] S3バケット ${BUCKET_NAME} を作成中..."
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"

  # バージョニング有効化
  aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  # SSE-S3 暗号化有効化
  aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }]
    }'

  # パブリックアクセスブロック有効化
  aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "[OK] S3バケット作成完了"
fi

# DynamoDBテーブル作成（ステートロック用）
if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${REGION}" 2>/dev/null; then
  echo "[SKIP] DynamoDBテーブル ${DYNAMODB_TABLE} は既に存在します"
else
  echo "[CREATE] DynamoDBテーブル ${DYNAMODB_TABLE} を作成中..."
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  echo "[OK] DynamoDBテーブル作成完了"
fi

echo ""
echo "=== バックエンド初期化完了 ==="
echo "次のステップ:"
echo "  cd terraform/environments/dev"
echo "  terraform init -backend-config=\"bucket=${BUCKET_NAME}\""
