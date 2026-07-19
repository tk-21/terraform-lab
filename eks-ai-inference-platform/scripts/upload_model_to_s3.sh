#!/bin/bash
# HuggingFaceからモデルをダウンロードしてS3にアップロードするスクリプト
# 初回セットアップ時のみ実行する (その後はEBSキャッシュを使用するため不要)
#
# 使い方:
#   ./scripts/upload_model_to_s3.sh [MODEL_NAME] [BUCKET_NAME]
#
# 事前準備:
#   terraform apply 後に以下で値を取得する
#   BUCKET_NAME=$(terraform -chdir=terraform/environments/dev output -raw model_cache_bucket_name)
#   VLLM_IRSA=$(terraform -chdir=terraform/environments/dev output -raw vllm_irsa_role_arn)
#
#   k8s/vllm/serviceaccount.yaml の VLLM_IRSA_ROLE_ARN を $VLLM_IRSA に置換する
#   k8s/vllm/configmap.yaml の REPLACE_WITH_BUCKET_NAME を $BUCKET_NAME に置換する

set -euo pipefail

MODEL_NAME="${1:-microsoft/Phi-3-mini-4k-instruct}"
BUCKET_NAME="${2:-}"

if [ -z "${BUCKET_NAME}" ]; then
  echo "エラー: BUCKET_NAME を第2引数で指定してください"
  echo "  例: $0 microsoft/Phi-3-mini-4k-instruct my-bucket-name"
  echo "  または: $0 microsoft/Phi-3-mini-4k-instruct \$(terraform -chdir=terraform/environments/dev output -raw model_cache_bucket_name)"
  exit 1
fi

LOCAL_DIR="${TMPDIR:-/tmp}/model-weights"

echo "=== Phase2: vLLMモデルキャッシュS3アップロード ==="
echo "モデル    : ${MODEL_NAME}"
echo "保存先    : s3://${BUCKET_NAME}/${MODEL_NAME}"
echo "ローカル  : ${LOCAL_DIR}/${MODEL_NAME}"
echo "======================================================="

# venv内でhuggingface-hubをインストール
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
  echo "huggingface-hubをインストール中..."
  pip install huggingface-hub --quiet
fi

# モデルダウンロード: PyTorchウェイトのみDL、他フレームワークのバイナリは除外してサイズ削減
echo "HuggingFaceからモデルをダウンロード中..."
python3 - <<PYTHON
from huggingface_hub import snapshot_download
import os

model_dir = os.path.join("${LOCAL_DIR}", "${MODEL_NAME}")
print(f"ダウンロード先: {model_dir}")

snapshot_download(
    repo_id="${MODEL_NAME}",
    local_dir=model_dir,
    # TensorFlow/Flax用バイナリは除外: vLLMはPyTorchのみ使用するため
    ignore_patterns=["*.msgpack", "*.h5", "flax_model*", "tf_model*", "rust_model*"],
)
print("ダウンロード完了")
PYTHON

# S3にアップロード: S3 Gateway Endpoint経由でVPC内から直接転送
echo "S3にアップロード中..."
aws s3 sync "${LOCAL_DIR}/${MODEL_NAME}/" \
  "s3://${BUCKET_NAME}/${MODEL_NAME}/" \
  --region ap-northeast-1 \
  --no-progress

echo ""
echo "=== アップロード完了 ==="
aws s3 ls "s3://${BUCKET_NAME}/${MODEL_NAME}/" --human-readable --summarize | tail -3

echo ""
echo "=== 次のステップ ==="
echo "1. k8s/vllm/configmap.yaml の REPLACE_WITH_BUCKET_NAME を ${BUCKET_NAME} に置換する"
echo "2. k8s/vllm/serviceaccount.yaml の VLLM_IRSA_ROLE_ARN を IRSAロールARNに置換する"
echo "   terraform -chdir=terraform/environments/dev output -raw vllm_irsa_role_arn"
echo "3. kubectl apply -f k8s/vllm/"
