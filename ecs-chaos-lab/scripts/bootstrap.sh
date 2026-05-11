#!/usr/bin/env bash
# ECR へのサンプル nginx イメージの初回プッシュスクリプト
# 使い方: ./scripts/bootstrap.sh
# 前提: Docker が起動済み、AWS CLI が設定済み

set -euo pipefail

REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME="ecl-dev-nginx"
REPO_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

echo "[INFO] ECR ログイン..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "[INFO] イメージビルド..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker build -t "${REPO_NAME}" "${SCRIPT_DIR}/../app/"

echo "[INFO] イメージタグ付け..."
docker tag "${REPO_NAME}:latest" "${REPO_URL}:latest"

echo "[INFO] ECR へのプッシュ..."
docker push "${REPO_URL}:latest"

echo "[SUCCESS] プッシュ完了: ${REPO_URL}:latest"
echo ""
echo "次のステップ:"
echo "  ECS Service が起動するまで待機:"
echo "  aws ecs wait services-stable \\"
echo "    --cluster ecl-dev-cluster \\"
echo "    --services ecl-dev-service \\"
echo "    --region ${REGION}"
