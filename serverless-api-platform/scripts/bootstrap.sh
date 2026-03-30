#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Terraform バックエンド用リソースを AWS CLI で作成する
#
# 使い方:
#   export AWS_PROFILE=your-profile
#   export AWS_REGION=ap-northeast-1
#   bash scripts/bootstrap.sh
#
# 作成リソース:
#   - S3 バケット: sap-tfstate-<account_id>
#       * KMS 暗号化 (aws/s3 マネージドキー)
#       * バージョニング有効
#       * パブリックアクセスブロック有効
#   - DynamoDB テーブル: sap-tfstate-lock
#       * LockID をパーティションキーとした tfstate ロック用
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# 設定値
# --------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

# AWS アカウント ID を取得
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "AWS Account ID: ${ACCOUNT_ID}"

S3_BUCKET="sap-tfstate-${ACCOUNT_ID}"
DYNAMODB_TABLE="sap-tfstate-lock"

echo "======================================================"
echo "  Terraform バックエンドリソース作成"
echo "  Bucket  : ${S3_BUCKET}"
echo "  Table   : ${DYNAMODB_TABLE}"
echo "  Region  : ${AWS_REGION}"
echo "======================================================"

# --------------------------------------------------------------------------
# S3 バケット作成
# --------------------------------------------------------------------------
echo ""
echo ">>> S3 バケット作成中..."

# us-east-1 の場合は LocationConstraint を指定しない
if [ "${AWS_REGION}" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "${S3_BUCKET}" \
    --region "${AWS_REGION}" \
    2>/dev/null || echo "バケット ${S3_BUCKET} は既に存在するかもしれません。続行します。"
else
  aws s3api create-bucket \
    --bucket "${S3_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}" \
    2>/dev/null || echo "バケット ${S3_BUCKET} は既に存在するかもしれません。続行します。"
fi

# --- KMS 暗号化 (aws/s3 マネージドキー) ---
echo ">>> S3 バケット暗号化を設定中..."
aws s3api put-bucket-encryption \
  --bucket "${S3_BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "alias/aws/s3"
      },
      "BucketKeyEnabled": true
    }]
  }'
echo "  暗号化: aws:kms (SSE-KMS, BucketKey 有効)"

# --- バージョニング有効化 ---
echo ">>> バージョニングを有効化中..."
aws s3api put-bucket-versioning \
  --bucket "${S3_BUCKET}" \
  --versioning-configuration Status=Enabled
echo "  バージョニング: Enabled"

# --- パブリックアクセスブロック ---
echo ">>> パブリックアクセスブロックを設定中..."
aws s3api put-public-access-block \
  --bucket "${S3_BUCKET}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  パブリックアクセス: すべてブロック"

# --- バケットポリシー: HTTPS のみ許可 ---
echo ">>> バケットポリシー (HTTPS 強制) を設定中..."
aws s3api put-bucket-policy \
  --bucket "${S3_BUCKET}" \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"DenyHTTP\",
      \"Effect\": \"Deny\",
      \"Principal\": \"*\",
      \"Action\": \"s3:*\",
      \"Resource\": [
        \"arn:aws:s3:::${S3_BUCKET}\",
        \"arn:aws:s3:::${S3_BUCKET}/*\"
      ],
      \"Condition\": {
        \"Bool\": {\"aws:SecureTransport\": \"false\"}
      }
    }]
  }"
echo "  バケットポリシー: HTTPS 強制 (HTTP 拒否)"

echo ""
echo "✓ S3 バケット作成完了: s3://${S3_BUCKET}"

# --------------------------------------------------------------------------
# DynamoDB テーブル作成 (tfstate ロック用)
# --------------------------------------------------------------------------
echo ""
echo ">>> DynamoDB テーブル作成中..."

# テーブルが既に存在するか確認
if aws dynamodb describe-table \
     --table-name "${DYNAMODB_TABLE}" \
     --region "${AWS_REGION}" \
     &>/dev/null; then
  echo "  テーブル ${DYNAMODB_TABLE} は既に存在します。スキップします。"
else
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}" \
    --tags \
      Key=Project,Value=serverless-api-platform \
      Key=ManagedBy,Value=bootstrap \
      Key=Environment,Value=shared

  echo "  テーブル作成後、ACTIVE 状態になるまで待機中..."
  aws dynamodb wait table-exists \
    --table-name "${DYNAMODB_TABLE}" \
    --region "${AWS_REGION}"
  echo "  ✓ テーブルが ACTIVE になりました"
fi

echo ""
echo "✓ DynamoDB テーブル作成完了: ${DYNAMODB_TABLE}"

# --------------------------------------------------------------------------
# 完了メッセージ
# --------------------------------------------------------------------------
echo ""
echo "======================================================"
echo "  Bootstrap 完了！"
echo ""
echo "  次のステップ:"
echo "  1. terraform/environments/dev/backend.tf の"
echo "     account_id プレースホルダを ${ACCOUNT_ID} に更新"
echo "     (または TF_VAR_account_id 環境変数を使用)"
echo ""
echo "  2. make init ENV=dev"
echo "======================================================"
