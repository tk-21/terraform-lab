#!/bin/bash
set -euo pipefail

# phase1_outputs.jsonからECR URLとアカウントIDを取得する
ACCOUNT_ID=$(jq -r '.aws_account_id.value' phase1_outputs.json)
REGION="ap-northeast-1"
PROCESSOR_URL=$(jq -r '.ecr_processor_url.value' phase1_outputs.json)
READER_URL=$(jq -r '.ecr_reader_url.value' phase1_outputs.json)

echo "=== ECRログイン ==="
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "=== processorイメージビルド & プッシュ ==="
# arm64でビルドする (Graviton2 Lambda対応)
# ローカルがx86_64の場合はbuildxを使ってクロスコンパイルする
docker buildx build \
  --platform linux/arm64 \
  --tag "${PROCESSOR_URL}:latest" \
  --push \
  lambda/processor/

echo "=== readerイメージビルド & プッシュ ==="
docker buildx build \
  --platform linux/arm64 \
  --tag "${READER_URL}:latest" \
  --push \
  lambda/reader/

echo "=== プッシュ完了 ==="
echo "processor: ${PROCESSOR_URL}:latest"
echo "reader:    ${READER_URL}:latest"

# image URIをファイルに保存 (Phase2のTerraform applyで使用)
cat > phase2_image_uris.env << EOF
PROCESSOR_IMAGE_URI=${PROCESSOR_URL}:latest
READER_IMAGE_URI=${READER_URL}:latest
EOF
echo "image URIを phase2_image_uris.env に保存しました"
