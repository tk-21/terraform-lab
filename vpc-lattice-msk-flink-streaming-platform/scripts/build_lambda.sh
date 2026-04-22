#!/bin/bash
set -euo pipefail

# Lambdaデプロイパッケージのビルドスクリプト
# 使い方: bash scripts/build_lambda.sh
#
# 注意: Python 3.12 + arm64 環境でビルドすること
# macOSの場合: docker run --platform linux/arm64 python:3.12-slim でビルド推奨

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE_DIR="${ROOT_DIR}/terraform/modules/lambda_producer"
PACKAGE_DIR="${MODULE_DIR}/package"
ZIP_PATH="${MODULE_DIR}/lambda_producer.zip"

echo "==> Cleaning up previous build artifacts..."
rm -rf "${PACKAGE_DIR}" "${ZIP_PATH}"
mkdir -p "${PACKAGE_DIR}"

echo "==> Installing Python dependencies..."
pip install \
  kafka-python-ng \
  aws-lambda-powertools \
  aws-msk-iam-sasl-signer \
  --target "${PACKAGE_DIR}" \
  --quiet

echo "==> Copying Lambda source..."
cp "${MODULE_DIR}/src/producer.py" "${PACKAGE_DIR}/"

echo "==> Creating deployment zip..."
cd "${PACKAGE_DIR}"
zip -r "${ZIP_PATH}" . --quiet

echo "==> Build complete: ${ZIP_PATH}"
ls -lh "${ZIP_PATH}"
