#!/usr/bin/env bash
# Terraformリモートステート用AWSリソースを作成するブートストラップスクリプト
# Terraformバックエンド自身はTerraformで管理しない慣例に従い、aws cliで作成する
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="istio-eks-tfstate-${AWS_ACCOUNT_ID}"
DYNAMODB_TABLE="istio-eks-tfstate-lock"

echo "==> AWSアカウントID: ${AWS_ACCOUNT_ID}"
echo "==> S3バケット: ${BUCKET_NAME}"
echo "==> DynamoDBテーブル: ${DYNAMODB_TABLE}"
echo ""

# S3バケット作成
echo "==> S3バケットを作成中..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "    バケット ${BUCKET_NAME} は既に存在します。スキップ。"
else
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"
  echo "    バケット作成完了。"
fi

# バージョニング有効化
echo "==> バージョニングを有効化..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

# パブリックアクセスブロック設定（全てブロック）
echo "==> パブリックアクセスをブロック..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# サーバーサイド暗号化設定（SSE-S3）
echo "==> SSE-S3暗号化を設定..."
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

# DynamoDBテーブル作成（tfstateロック用）
echo "==> DynamoDBテーブルを作成中..."
if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${AWS_REGION}" 2>/dev/null; then
  echo "    テーブル ${DYNAMODB_TABLE} は既に存在します。スキップ。"
else
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}"
  echo "    DynamoDBテーブル作成完了。"
fi

echo ""
echo "==> ブートストラップ完了！"
echo ""
echo "次のステップ: backend.tf のバケット名を置換してください。"
echo ""
echo "実行コマンド:"
echo "  sed -i 's/REPLACE_WITH_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g' terraform/backend.tf"
echo ""
echo "その後:"
echo "  cd terraform && terraform init"
