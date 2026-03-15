#!/usr/bin/env bash
set -euo pipefail

REGION=$(cd infra && terraform output -raw region)
REPO=$(cd infra && terraform output -raw ecr_repo_url)
TAG=${1:-dev}

aws ecr get-login-password --region "$REGION" \
 | docker login --username AWS --password-stdin "${REPO%/*}"

docker build -t "${REPO}:${TAG}" ./app
docker push "${REPO}:${TAG}"

echo "Pushed: ${REPO}:${TAG}"