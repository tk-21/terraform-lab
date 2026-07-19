#!/bin/bash
# S3 Public Access 違反を意図的に作成するスクリプト (テスト用)
# ⚠️ テスト後は必ず手動で修復 or 自動修復の確認後削除すること

set -euo pipefail

BUCKET_NAME="csar-test-violation-$(date +%s)"
REGION="ap-northeast-1"

echo "=== S3違反バケット作成: ${BUCKET_NAME} ==="

# バケット作成
aws s3api create-bucket \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --create-bucket-configuration LocationConstraint="${REGION}"

# Public Access Block を意図的に無効化 (違反状態)
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

echo "違反バケット作成完了: ${BUCKET_NAME}"
echo "Config Ruleが評価されるまで数分待つこと"
echo ""
echo "手動でConfig Rule評価をトリガーする場合:"
echo "  aws configservice start-config-rules-evaluation --config-rule-names csar-s3-bucket-public-read-prohibited"
echo ""
echo "数分後に評価結果を確認:"
echo "  aws configservice get-compliance-details-by-config-rule \\"
echo "    --config-rule-name csar-s3-bucket-public-read-prohibited \\"
echo "    --compliance-types NON_COMPLIANT"
echo ""
echo "テスト後のクリーンアップ:"
echo "  aws s3 rb s3://${BUCKET_NAME} --force"
