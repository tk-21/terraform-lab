#!/usr/bin/env bash
set -euo pipefail

# tfstate バックエンド初期化スクリプト
# 冪等設計: 既存リソースがあればスキップして続行する

REGION="ap-northeast-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="s3t-prod-tfstate-${AWS_ACCOUNT_ID}"
DYNAMODB_TABLE="s3t-prod-tfstate-lock"

echo "=== Bootstrapping tfstate backend ==="
echo "Account ID : ${AWS_ACCOUNT_ID}"
echo "Region     : ${REGION}"
echo "Bucket     : ${BUCKET_NAME}"
echo "DynamoDB   : ${DYNAMODB_TABLE}"
echo ""

# ── S3 バケット ──────────────────────────────────────────────────────────────

if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "[SKIP] S3 bucket already exists: ${BUCKET_NAME}"
else
  echo "[CREATE] S3 bucket: ${BUCKET_NAME}"
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"

  # バージョニング有効化
  aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  # SSE-S3 暗号化 (KMS移行時は aws:kms に変更するだけでよい構造にしておく)
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

  # パブリックアクセス全ブロック
  aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  # バケットポリシー: HTTPS 強制
  aws s3api put-bucket-policy \
    --bucket "${BUCKET_NAME}" \
    --policy "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Sid\": \"DenyNonTLS\",
        \"Effect\": \"Deny\",
        \"Principal\": \"*\",
        \"Action\": \"s3:*\",
        \"Resource\": [
          \"arn:aws:s3:::${BUCKET_NAME}\",
          \"arn:aws:s3:::${BUCKET_NAME}/*\"
        ],
        \"Condition\": {
          \"Bool\": { \"aws:SecureTransport\": \"false\" }
        }
      }]
    }"

  echo "[DONE] S3 bucket created: ${BUCKET_NAME}"
fi

# ── DynamoDB テーブル ────────────────────────────────────────────────────────

if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${REGION}" 2>/dev/null; then
  echo "[SKIP] DynamoDB table already exists: ${DYNAMODB_TABLE}"
else
  echo "[CREATE] DynamoDB table: ${DYNAMODB_TABLE}"
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" \
    --tags \
      Key=Project,Value=secure-3tier-iac-pipeline \
      Key=Environment,Value=prod \
      Key=ManagedBy,Value=script \
      Key=Owner,Value=platform-team

  aws dynamodb wait table-exists \
    --table-name "${DYNAMODB_TABLE}" \
    --region "${REGION}"

  echo "[DONE] DynamoDB table created: ${DYNAMODB_TABLE}"
fi

# ── terraform init 用バックエンド設定の表示 ──────────────────────────────────

cat <<EOF

=== Backend configuration (copy to backend.tf or use -backend-config) ===

terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    key            = "prod/terraform.tfstate"
    region         = "${REGION}"
    encrypt        = true
    dynamodb_table = "${DYNAMODB_TABLE}"
  }
}

=== Next steps ===
1. Update terraform/envs/prod/backend.tf with the bucket name above
2. cd terraform/envs/prod
3. terraform init
4. terraform plan -var-file=terraform.tfvars
EOF
