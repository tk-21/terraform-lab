#!/usr/bin/env bash
# =============================================================
# CloudWatch Container Insights 有効化
# amazon-cloudwatch-observability EKSアドオンをインストールする
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "📊 Container Insights 有効化: ${CLUSTER_NAME}"

# CloudWatch Agent + FluentBit をEKSアドオンとしてインストール
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name amazon-cloudwatch-observability \
  --region "${REGION}" \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-node-role" \
  2>/dev/null || echo "アドオンは既にインストール済みです"

# インストール完了を待機
echo "⏳ アドオン起動待機..."
aws eks wait addon-active \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name amazon-cloudwatch-observability \
  --region "${REGION}" \
  2>/dev/null || true

# ステータス確認
STATUS=$(aws eks describe-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name amazon-cloudwatch-observability \
  --region "${REGION}" \
  --query "addon.status" \
  --output text)

echo "✅ Container Insights ステータス: ${STATUS}"
echo ""
echo "CloudWatch Logsグループ確認:"
echo "  aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/${CLUSTER_NAME}"
