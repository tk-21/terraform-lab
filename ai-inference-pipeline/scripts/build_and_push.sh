#!/bin/bash
# ECRへのDockerイメージビルド&プッシュスクリプト
# arm64(Graviton2)向けにビルドする点が重要（x86_64ではFargateで動作しない）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# terraform outputからECR URLを取得
ECR_URL=$(cd "$PROJECT_ROOT/terraform/environments/dev" && terraform output -raw ecr_repository_url)
AWS_REGION=${AWS_REGION:-"ap-northeast-1"}
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_TAG=${IMAGE_TAG:-"latest"}

echo "=== ECRログイン ==="
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

echo "=== ビルド開始 (arm64) ==="
docker buildx build \
  --platform linux/arm64 \
  --tag "$ECR_URL:$IMAGE_TAG" \
  --push \
  "$PROJECT_ROOT/docker/preprocessor"

echo "=== プッシュ完了 ==="
echo "Image: $ECR_URL:$IMAGE_TAG"
