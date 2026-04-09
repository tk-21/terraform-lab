#!/usr/bin/env bash
set -euo pipefail

# ローカルでビルドした app イメージを ECR に push する。
REGION=$(cd infra && terraform output -raw region)
REPO=$(cd infra && terraform output -raw ecr_repo_url)
TAG=${1:-dev}

# ECR の認証トークンで Docker ログインする。
aws ecr get-login-password --region "$REGION" \
 | docker login --username AWS --password-stdin "${REPO%/*}"

# app ディレクトリをそのままコンテナ化して push する。
docker build -t "${REPO}:${TAG}" ./app
docker push "${REPO}:${TAG}"

echo "Pushed: ${REPO}:${TAG}"
