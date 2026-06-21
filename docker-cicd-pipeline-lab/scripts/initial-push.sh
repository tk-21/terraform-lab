#!/usr/bin/env bash
# 初回 ECR push スクリプト
# terraform apply 直後に一度だけ実行する

set -euo pipefail

REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME="cicd-lab-prod-app"
REPO_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"

echo "=== ECR ログイン ==="
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "=== arm64 イメージビルド & push ==="
docker buildx create --use --name mybuilder 2>/dev/null || true
docker buildx build \
  --platform linux/arm64 \
  -t "$REPO_URI:latest" \
  -t "$REPO_URI:initial" \
  ./app \
  --push

echo "=== ECS サービス再起動 ==="
aws ecs update-service \
  --cluster cicd-lab-prod-cluster \
  --service cicd-lab-prod-service \
  --force-new-deployment \
  --query 'service.deployments[0].status' \
  --output text

echo "=== タスク起動待機 (~1-2分) ==="
aws ecs wait services-stable \
  --cluster cicd-lab-prod-cluster \
  --services cicd-lab-prod-service

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names cicd-lab-prod-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

echo ""
echo "✅ デプロイ完了"
echo "   ALB: http://$ALB_DNS"
curl -s "http://$ALB_DNS/health" | python3 -m json.tool
