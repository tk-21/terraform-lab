#!/bin/bash
# リソース全削除スクリプト
# 順序に注意: Kubernetes リソース → Istio → EKS → VPC → S3/DynamoDB
set -euo pipefail

# スクリプト自体の絶対パスを取得（シンボリックリンク対応）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TERRAFORM_DIR="$(dirname "${SCRIPT_DIR}")/terraform"

echo "Kubernetes リソースを削除中..."
kubectl delete namespace mesh-apps --ignore-not-found || echo "警告: mesh-apps namespace の削除に失敗しました（継続）"

echo "Istio をアンインストール中..."
if command -v istioctl &> /dev/null; then
  istioctl uninstall --purge -y || echo "警告: Istio アンインストール失敗（継続）"
  kubectl delete namespace istio-system --ignore-not-found
else
  echo "警告: istioctl がインストールされていません。スキップします"
fi

echo "Terraform で AWS リソースを削除中..."
if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "エラー: Terraform ディレクトリが見つかりません: ${TERRAFORM_DIR}"
  exit 1
fi
cd "${TERRAFORM_DIR}"
terraform destroy -auto-approve

echo "Terraform バックエンドリソースを削除中..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || {
  echo "エラー: AWS アカウント ID の取得に失敗しました"
  exit 1
}
BUCKET="istio-eks-tfstate-${ACCOUNT_ID}"

echo "  S3 バケット ${BUCKET} を空にしています..."
# バージョン管理が有効な場合、オブジェクト・バージョン・削除マーカーを全て削除する
aws s3api list-object-versions --bucket "${BUCKET}" --output json 2>/dev/null \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data.get('Versions', []):
    print(v['Key'], v['VersionId'])
" | while read -r key version; do
    aws s3api delete-object --bucket "${BUCKET}" --key "${key}" --version-id "${version}"
  done

aws s3api list-object-versions --bucket "${BUCKET}" --output json 2>/dev/null \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('DeleteMarkers', []):
    print(m['Key'], m['VersionId'])
" | while read -r key version; do
    aws s3api delete-object --bucket "${BUCKET}" --key "${key}" --version-id "${version}"
  done

aws s3 rb "s3://${BUCKET}" || echo "警告: バケット削除に失敗しました。S3 コンソールで確認してください"

aws dynamodb delete-table \
  --table-name istio-eks-tfstate-lock \
  --region ap-northeast-1

echo "全リソースの削除が完了しました"
