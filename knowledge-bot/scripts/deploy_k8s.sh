#!/usr/bin/env bash
set -euo pipefail

# EKS へアプリ一式を順番に適用するデプロイスクリプト。
NS="knowledgebot"
APP_NAME="knowledgebot"

# Terraform outputs を短く参照するための補助関数。
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
# kubectl が対象 EKS クラスタへ接続できるようにする。
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

echo "[*] Apply namespace..."
kubectl apply -f k8s/base/namespace.yaml

echo "[*] Apply app ConfigMap/Secret..."
# ConfigMap のプレースホルダを Terraform 出力や環境変数で置換して適用する。
tmp_cfg="$(mktemp)"
sed -e "s|REPLACE_AWS_REGION|${REGION}|g" \
    -e "s|REPLACE_RAG_MODE|${RAG_MODE}|g" \
    -e "s|REPLACE_BEDROCK_MODEL_ID|${MODEL_ID}|g" \
    -e "s|REPLACE_KNOWLEDGE_BASE_ID|${KB_ID}|g" \
    k8s/base/configmap.yaml > "${tmp_cfg}"
kubectl apply -f "${tmp_cfg}"

# 機密寄りの値は Secret として別管理にする。
kubectl -n "${NS}" create secret generic knowledgebot-secrets \
  --from-literal=KB_MODEL_ARN="${KB_MODEL_ARN}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ "${RAG_MODE}" == "KB" && ( -z "${KB_ID}" || "${KB_ID}" == "null" ) ]]; then
  echo "    - WARN: RAG_MODE=KB ですが knowledge_base_id が空です。"
fi

echo "[*] Apply ServiceAccount (IRSA)..."
# ServiceAccount にアプリ用 IAM ロール ARN を差し込む。
sed "s|REPLACE_WITH_IRSA_APP_ROLE_ARN|${IRSA_ROLE_ARN}|g" k8s/base/serviceaccount.yaml | kubectl apply -f -

echo "[*] Apply Deployment..."
# Deployment のイメージタグだけ差し替えて適用する。
tmp_deploy="$(mktemp)"
cat k8s/base/deployment.yaml \
  | sed "s|REPLACE_WITH_ECR_IMAGE|${IMAGE}|g" \
  > "${tmp_deploy}"
kubectl apply -f "${tmp_deploy}"

echo "[*] Apply Service..."
kubectl apply -f k8s/base/service.yaml

echo "[*] Apply Ingress..."
tmp_ing="$(mktemp)"

# ALB のアクセスログ出力先 annotation を必要時だけ差し込む。
ALB_ATTR="access_logs.s3.enabled=true,access_logs.s3.bucket=${ALB_LOG_BUCKET},access_logs.s3.prefix=${APP_NAME}"

cat k8s/base/ingress.yaml > "${tmp_ing}"

# ALB ログ用バケットがある場合だけ annotation を追加する。
if [[ -n "${ALB_LOG_BUCKET}" && "${ALB_LOG_BUCKET}" != "null" ]]; then
  # 既存 annotation が無いときだけ追記して二重定義を避ける。
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
# 最後に主要リソースの状態をまとめて確認する。
kubectl -n "${NS}" get deploy,svc,ingress,pdb
