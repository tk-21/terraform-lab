#!/usr/bin/env bash
# =============================================================
# AWS Load Balancer Controller Helmインストール
# 前提: ALB Controller IAMロールがTerraformで作成済みであること
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"

# VPC IDをTerraform outputから取得
VPC_ID=$(cd "$(dirname "$0")/../terraform" && terraform output -raw vpc_id)

echo "Installing AWS Load Balancer Controller..."
echo "  Cluster: ${CLUSTER_NAME}"
echo "  VPC ID:  ${VPC_ID}"

helm repo add eks https://aws.github.io/eks-charts
helm repo update

# ALB Controller SAのアノテーションにある実際のロールARNをTerraform outputから取得
ROLE_ARN=$(cd "$(dirname "$0")/../terraform" && terraform output -raw alb_controller_role_arn)

# ServiceAccountのアノテーションを実際のARNで更新
sed -i "s|arn:aws:iam::ACCOUNT_ID:role/eks-chaos-cell-prod-alb-controller|${ROLE_ARN}|g" \
  "$(dirname "$0")/../k8s/ingress/alb-controller-sa.yaml"

kubectl apply -f "$(dirname "$0")/../k8s/ingress/alb-controller-sa.yaml"

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}"

echo "Waiting for ALB Controller to be ready..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

echo "ALB Controller installed successfully."
