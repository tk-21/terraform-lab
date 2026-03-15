#!/usr/bin/env bash
set -euo pipefail

NS="knowledgebot"
APP_NAME="knowledgebot"
OIDC_SECRET_NAME="oidc-client-secret"

# --- terraform outputs ---
tf() { (cd infra && terraform output -raw "$1"); }

REGION="$(tf region)"
CLUSTER="$(tf cluster_name)"
IRSA_ROLE_ARN="$(tf irsa_app_role_arn)"
IMAGE="${APP_IMAGE:-$(tf app_image)}"
ALB_LOG_BUCKET="$(tf alb_logs_bucket)"

OIDC_ISSUER="$(tf oidc_issuer)"
OIDC_AUTHZ="$(tf oidc_authorization_endpoint)"
OIDC_TOKEN="$(tf oidc_token_endpoint)"
OIDC_USERINFO="$(tf oidc_userinfo_endpoint)"
OIDC_CLIENT_ID="$(tf cognito_client_id)"
OIDC_CLIENT_SECRET="$(cd infra && terraform output -json cognito_client_secret | jq -r '.')"

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

echo "[*] Ensure OIDC secret (only if Cognito outputs exist)..."
if [[ -n "${OIDC_CLIENT_SECRET}" && "${OIDC_CLIENT_SECRET}" != "null" && -n "${OIDC_CLIENT_ID}" && "${OIDC_CLIENT_ID}" != "null" ]]; then
  kubectl -n "${NS}" create secret generic "${OIDC_SECRET_NAME}" \
    --from-literal=clientID="${OIDC_CLIENT_ID}" \
    --from-literal=clientSecret="${OIDC_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "    - Cognito client secret not found. Skipping OIDC secret."
fi

echo "[*] Apply Ingress..."
# OIDC annotation JSON を埋める（Cognito Hosted UI想定）
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

# OIDCが揃っているなら auth-idp-oidc を埋める
if [[ -n "${OIDC_ISSUER}" && "${OIDC_ISSUER}" != "null" && -n "${OIDC_AUTHZ}" && "${OIDC_AUTHZ}" != "null" ]]; then
  if ! grep -q '^    alb.ingress.kubernetes.io/auth-type:' "${tmp_ing}"; then
    awk -v issuer="${OIDC_ISSUER}" \
        -v authz="${OIDC_AUTHZ}" \
        -v token="${OIDC_TOKEN}" \
        -v userinfo="${OIDC_USERINFO}" \
        -v secret="${OIDC_SECRET_NAME}" '
      {
        print
        if ($0 ~ /^  annotations:/) {
          print "    alb.ingress.kubernetes.io/auth-type: oidc"
          print "    alb.ingress.kubernetes.io/auth-scope: \"openid\""
          print "    alb.ingress.kubernetes.io/auth-session-timeout: \"3600\""
          print "    alb.ingress.kubernetes.io/auth-on-unauthenticated-request: authenticate"
          print "    alb.ingress.kubernetes.io/auth-idp-oidc: >"
          print "      {\"issuer\":\"" issuer "\",\"authorizationEndpoint\":\"" authz "\",\"tokenEndpoint\":\"" token "\",\"userInfoEndpoint\":\"" userinfo "\",\"secretName\":\"" secret "\"}"
        }
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
