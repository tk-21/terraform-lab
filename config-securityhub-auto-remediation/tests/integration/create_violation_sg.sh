#!/bin/bash
# Security Group SSH 0.0.0.0/0 違反を作成するスクリプト (テスト用)
# ⚠️ テスト後は必ず手動で修復 or 自動修復の確認後削除すること

set -euo pipefail

REGION="ap-northeast-1"

echo "=== Security Group違反リソース作成 ==="

# csar-vpc のVPC IDを取得する
VPC_ID=$(aws ec2 describe-vpcs \
  --region "${REGION}" \
  --filters "Name=tag:Name,Values=csar-vpc" \
  --query "Vpcs[0].VpcId" --output text)

if [ "${VPC_ID}" = "None" ] || [ -z "${VPC_ID}" ]; then
  echo "ERROR: csar-vpcが見つかりません。Phase1のnetworkingモジュールが適用済みか確認してください。"
  exit 1
fi

echo "対象VPC: ${VPC_ID}"

SG_NAME="csar-test-violation-sg-$(date +%s)"
SG_ID=$(aws ec2 create-security-group \
  --region "${REGION}" \
  --group-name "${SG_NAME}" \
  --description "テスト用違反SG (自動修復テスト後に削除)" \
  --vpc-id "${VPC_ID}" \
  --query "GroupId" --output text)

echo "Security Group作成完了: ${SG_ID}"

# SSH 0.0.0.0/0 を意図的に開放する (違反状態)
aws ec2 authorize-security-group-ingress \
  --region "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

echo "SSH 0.0.0.0/0 インバウンドルール追加完了 (違反状態)"
echo ""
echo "Config Rule評価をトリガー:"
echo "  aws configservice start-config-rules-evaluation --config-rule-names csar-restricted-ssh"
echo ""
echo "数分後に評価結果を確認:"
echo "  aws configservice get-compliance-details-by-config-rule \\"
echo "    --config-rule-name csar-restricted-ssh \\"
echo "    --compliance-types NON_COMPLIANT"
echo ""
echo "テスト後のクリーンアップ:"
echo "  aws ec2 delete-security-group --group-id ${SG_ID}"
