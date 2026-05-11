#!/usr/bin/env bash
# =============================================================
# EKS セットアップ一括スクリプト
# terraform apply 後に実行してkubeconfigを設定する
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"

echo "🚀 EKS セットアップ開始: ${CLUSTER_NAME}"

# kubeconfig 更新
aws eks update-kubeconfig \
  --region "${REGION}" \
  --name "${CLUSTER_NAME}"

# 接続確認
echo "📋 ノード確認..."
kubectl get nodes -o wide

# AWS Load Balancer Controller のインストール（helm）
echo "📦 AWS Load Balancer Controller インストール..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# CoreDNS / kube-proxy / VPC CNI のアドオン確認
echo "📋 EKSアドオン確認..."
aws eks list-addons --cluster-name "${CLUSTER_NAME}" --region "${REGION}"

echo "✅ セットアップ完了"
echo ""
echo "次のステップ:"
echo "  claude < phase2.md  # Karpenter導入"
