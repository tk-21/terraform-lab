#!/usr/bin/env bash
set -euo pipefail

NS="knowledgebot"
APP_NAME="knowledgebot"

# --- terraform outputs ---
tf() { (cd infra && terraform output -raw "$1"); }

REGION="$(tf region)"
CLUSTER="$(tf cluster_name)"
IRSA_ROLE_ARN="$(tf irsa_app_role_arn)"
IMAGE="${APP_IMAGE:-$(tf app_image)}"
ALB_LOG_BUCKET="$(tf alb_logs_bucket)"

# KB (optional)
KB_ID="$(tf knowledge_base_id || true)"
RAG_MODE="${RAG_MODE:-MVP}"
MODEL_ID="${BEDROCK_MODEL_ID:-anthropic.claude-3-5-sonnet-20240620-v1:0}"
KB_MODEL_ARN="${KB_MODEL_ARN:-}"

echo "[*] Update kubeconfig..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

echo "[*] Apply namespace..."
kubectl apply -f k8s/base/namespace.yaml

echo "[*] Apply app ConfigMap/Secret..."
tmp_cfg="$(mktemp)"
sed -e "s|REPLACE_AWS_REGION|${REGION}|g" \
    -e "s|REPLACE_RAG_MODE|${RAG_MODE}|g" \
    -e "s|REPLACE_BEDROCK_MODEL_ID|${MODEL_ID}|g" \
    -e "s|REPLACE_KNOWLEDGE_BASE_ID|${KB_ID}|g" \
    k8s/base/configmap.yaml > "${tmp_cfg}"
kubectl apply -f "${tmp_cfg}"

kubectl -n "${NS}" create secret generic knowledgebot-secrets \
  --from-literal=KB_MODEL_ARN="${KB_MODEL_ARN}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ "${RAG_MODE}" == "KB" && ( -z "${KB_ID}" || "${KB_ID}" == "null" ) ]]; then
  echo "    - WARN: RAG_MODE=KB ですが knowledge_base_id が空です。"
fi

echo "[*] Apply ServiceAccount (IRSA)..."
sed "s|REPLACE_WITH_IRSA_APP_ROLE_ARN|${IRSA_ROLE_ARN}|g" k8s/base/serviceaccount.yaml | kubectl apply -f -

echo "[*] Apply Deployment..."
tmp_deploy="$(mktemp)"
cat k8s/base/deployment.yaml \
  | sed "s|REPLACE_WITH_ECR_IMAGE|${IMAGE}|g" \
  > "${tmp_deploy}"
kubectl apply -f "${tmp_deploy}"

echo "[*] Apply Service..."
kubectl apply -f k8s/base/service.yaml

echo "[*] Apply Ingress..."
tmp_ing="$(mktemp)"

# ALB access logs annotation
ALB_ATTR="access_logs.s3.enabled=true,access_logs.s3.bucket=${ALB_LOG_BUCKET},access_logs.s3.prefix=${APP_NAME}"

cat k8s/base/ingress.yaml > "${tmp_ing}"

# ログbucket差し込み
if [[ -n "${ALB_LOG_BUCKET}" && "${ALB_LOG_BUCKET}" != "null" ]]; then
  # ingress.yaml 内に load-balancer-attributes が無ければ追記
  if ! grep -q "alb.ingress.kubernetes.io/load-balancer-attributes" "${tmp_ing}"; then
    awk -v attr="${ALB_ATTR}" '
      {print}
      $0 ~ /^  annotations:/ {
        print "    alb.ingress.kubernetes.io/load-balancer-attributes: >"
        print "      " attr
      }
    ' "${tmp_ing}" > "${tmp_ing}.new" && mv "${tmp_ing}.new" "${tmp_ing}"
  fi
fi

kubectl apply -f "${tmp_ing}"

echo "[*] Apply HPA..."
kubectl apply -f k8s/base/hpa.yaml

echo "[*] Apply PDB..."
kubectl apply -f k8s/base/pdb.yaml

echo
echo "[*] Status:"
kubectl -n "${NS}" get deploy,svc,ingress,pdb
