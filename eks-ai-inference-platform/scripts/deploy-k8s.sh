#!/usr/bin/env bash
# k8sマニフェストのプレースホルダーをTerraform outputで置換してapplyするスクリプト
# 前提: terraform apply 完了済み / kubectl が対象クラスターに接続済み
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/environments/dev"
K8S_DIR="${REPO_ROOT}/k8s"
TMP_DIR="${TMPDIR:-/tmp}/eks-ai-inf-k8s-$$"
mkdir -p "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "=== Terraform output を取得 ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME=$(terraform -chdir="${TF_DIR}" output -raw cluster_name)
VLLM_IRSA=$(terraform -chdir="${TF_DIR}" output -raw vllm_irsa_role_arn)
GATEWAY_IRSA=$(terraform -chdir="${TF_DIR}" output -raw gateway_irsa_role_arn)
OTEL_IRSA=$(terraform -chdir="${TF_DIR}" output -raw otel_collector_irsa_arn)
MODEL_BUCKET=$(terraform -chdir="${TF_DIR}" output -raw model_cache_bucket_name)
AMP_WORKSPACE_ID=$(terraform -chdir="${TF_DIR}" output -raw amp_workspace_id)
AMP_REMOTE_WRITE_URL=$(terraform -chdir="${TF_DIR}" output -raw amp_remote_write_url)
ECR_REPO_URL=$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)
KEDA_IRSA_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-keda-amp-irsa"

echo "ACCOUNT_ID         : ${ACCOUNT_ID}"
echo "CLUSTER_NAME       : ${CLUSTER_NAME}"
echo "VLLM_IRSA          : ${VLLM_IRSA}"
echo "GATEWAY_IRSA       : ${GATEWAY_IRSA}"
echo "OTEL_IRSA          : ${OTEL_IRSA}"
echo "MODEL_BUCKET       : ${MODEL_BUCKET}"
echo "AMP_WORKSPACE_ID   : ${AMP_WORKSPACE_ID}"
echo "ECR_REPO_URL       : ${ECR_REPO_URL}"

echo ""
echo "=== プレースホルダーを置換しつつ一時ディレクトリにコピー ==="

# コピー関数: sed でプレースホルダーを一括置換する
replace_and_copy() {
  local src="$1"
  local rel="${src#${K8S_DIR}/}"
  local dst="${TMP_DIR}/${rel}"
  mkdir -p "$(dirname "${dst}")"
  sed \
    -e "s|ACCOUNT_ID|${ACCOUNT_ID}|g" \
    -e "s|VLLM_IRSA_ROLE_ARN|${VLLM_IRSA}|g" \
    -e "s|GATEWAY_IRSA_ROLE_ARN|${GATEWAY_IRSA}|g" \
    -e "s|arn:aws:iam::ACCOUNT_ID:role/eks-ai-inf-dev-otel-collector|${OTEL_IRSA}|g" \
    -e "s|arn:aws:iam::ACCOUNT_ID:role/eks-ai-inf-dev-keda-amp-irsa|${KEDA_IRSA_ARN}|g" \
    -e "s|REPLACE_WITH_BUCKET_NAME|${MODEL_BUCKET}|g" \
    -e "s|workspaces/WORKSPACE_ID|workspaces/${AMP_WORKSPACE_ID}|g" \
    -e "s|eks-ai-inf-dev-cluster|${CLUSTER_NAME}|g" \
    -e "s|ACCOUNT_ID.dkr.ecr.ap-northeast-1.amazonaws.com/ai-gateway:latest|${ECR_REPO_URL}:latest|g" \
    "${src}" > "${dst}"
}

# 全 YAML ファイルを処理する
find "${K8S_DIR}" -name "*.yaml" | while read -r f; do
  replace_and_copy "${f}"
done

echo ""
echo "=== otel-amp-config Secret を作成 (存在する場合は上書き) ==="
kubectl create secret generic otel-amp-config \
  --from-literal=remote_write_url="${AMP_REMOTE_WRITE_URL}" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== マニフェストをapply (Namespace → RBAC → その他の順) ==="

# Namespace を先に作成する
for ns_file in "${TMP_DIR}"/*/namespace.yaml; do
  [ -f "${ns_file}" ] && kubectl apply -f "${ns_file}"
done

# RBAC を適用する
for rbac_file in "${TMP_DIR}"/*/rbac.yaml; do
  [ -f "${rbac_file}" ] && kubectl apply -f "${rbac_file}"
done

# ServiceAccount を適用する
for sa_file in "${TMP_DIR}"/*/serviceaccount.yaml; do
  [ -f "${sa_file}" ] && kubectl apply -f "${sa_file}"
done

# otel cluster-config ConfigMap を先に適用する (collector.yaml が参照するため)
[ -f "${TMP_DIR}/otel/cluster-config.yaml" ] && kubectl apply -f "${TMP_DIR}/otel/cluster-config.yaml"

# 残りのマニフェストを適用する
kubectl apply -R -f "${TMP_DIR}/"

echo ""
echo "=== デプロイ完了 ==="
echo "Pod 確認: kubectl get pods -A"
