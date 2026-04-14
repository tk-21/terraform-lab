#!/usr/bin/env bash
# bootstrap.sh — tfstate 用 S3 バケットと DynamoDB テーブルを作成する。
# Terraform 初回実行前に一度だけ実行すること。
#
# 使い方:
#   AWS_PROFILE=your-profile bash scripts/bootstrap.sh
#
# 前提条件:
#   - AWS CLI がインストールされていること
#   - 十分な IAM 権限があること（S3:CreateBucket, DynamoDB:CreateTable, KMS:CreateKey）

set -euo pipefail

# ============================================================
# 設定値
# ============================================================
REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="sep-tfstate-${ACCOUNT_ID}"
DYNAMODB_TABLE="sep-tfstate-lock"
KMS_ALIAS="alias/sep-tfstate-key"

echo "==================================================="
echo " serverless-event-pipeline tfstate bootstrap"
echo "==================================================="
echo "  Region     : ${REGION}"
echo "  Account ID : ${ACCOUNT_ID}"
echo "  S3 Bucket  : ${BUCKET_NAME}"
echo "  DynamoDB   : ${DYNAMODB_TABLE}"
echo "==================================================="
echo ""

# ============================================================
# KMS キーの作成（S3 バケット暗号化用）
# ============================================================
echo "[1/4] KMS キーを作成します..."

# 既存のエイリアスがあればスキップ
if aws kms describe-key --key-id "${KMS_ALIAS}" --region "${REGION}" &>/dev/null; then
  echo "  -> KMS キー ${KMS_ALIAS} は既に存在します。スキップします。"
else
  KMS_KEY_ID=$(aws kms create-key \
    --description "sep tfstate S3 encryption key" \
    --region "${REGION}" \
    --query KeyMetadata.KeyId \
    --output text)

  aws kms create-alias \
    --alias-name "${KMS_ALIAS}" \
    --target-key-id "${KMS_KEY_ID}" \
    --region "${REGION}"

  echo "  -> KMS キーを作成しました: ${KMS_KEY_ID}"
fi

# ============================================================
# S3 バケットの作成（バージョニング + 暗号化 + パブリックアクセスブロック）
# ============================================================
echo "[2/4] S3 バケットを作成します..."

if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "  -> S3 バケット ${BUCKET_NAME} は既に存在します。スキップします。"
else
  # ap-northeast-1 は LocationConstraint の指定が必要
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"

  # バージョニング有効化（ステートファイルの誤削除・破損対策）
  aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  # KMS による SSE 暗号化を強制する
  aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms",
          "KMSMasterKeyID": "'"${KMS_ALIAS}"'"
        },
        "BucketKeyEnabled": true
      }]
    }'

  # パブリックアクセスを完全ブロックする
  aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "  -> S3 バケットを作成しました: ${BUCKET_NAME}"
fi

# ============================================================
# DynamoDB テーブルの作成（ステートロック用）
# ============================================================
echo "[3/4] DynamoDB テーブルを作成します..."

if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${REGION}" &>/dev/null; then
  echo "  -> DynamoDB テーブル ${DYNAMODB_TABLE} は既に存在します。スキップします。"
else
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  # テーブルが ACTIVE になるまで待機する
  aws dynamodb wait table-exists \
    --table-name "${DYNAMODB_TABLE}" \
    --region "${REGION}"

  echo "  -> DynamoDB テーブルを作成しました: ${DYNAMODB_TABLE}"
fi

# ============================================================
# backend.tf の bucket 名を自動更新する
# ============================================================
echo "[4/4] backend.tf を更新します..."

BACKEND_FILE="terraform/environments/dev/backend.tf"
if [ -f "${BACKEND_FILE}" ]; then
  sed -i "s/sep-tfstate-REPLACE_WITH_ACCOUNT_ID/${BUCKET_NAME}/g" "${BACKEND_FILE}"
  echo "  -> ${BACKEND_FILE} の bucket 名を ${BUCKET_NAME} に更新しました。"
fi

# ============================================================
# 完了メッセージ
# ============================================================
echo ""
echo "==================================================="
echo " bootstrap 完了！"
echo "==================================================="
echo ""
echo "次のステップ:"
echo "  make init ENV=dev"
echo "  make plan ENV=dev"
echo ""
