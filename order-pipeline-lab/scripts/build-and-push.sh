#!/bin/bash
set -euo pipefail

REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
REPO_NAME="order-pipeline/payment-processor"

echo "=== ECR ログイン ==="
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ECR_URL}"

echo "=== Docker ビルド (arm64) ==="
# なぜ: --platform で arm64 を明示。Fargate の ARM64 タスクに対応
docker buildx build \
  --platform linux/arm64 \
  --tag "${ECR_URL}/${REPO_NAME}:latest" \
  --tag "${ECR_URL}/${REPO_NAME}:$(git rev-parse --short HEAD 2>/dev/null || echo 'local')" \
  --push \
  ./ecs/payment-processor/

echo "=== プッシュ完了 ==="
echo "Image: ${ECR_URL}/${REPO_NAME}:latest"
