#!/usr/bin/env bash
set -euo pipefail

# Terraform destroy 前に、Kubernetes 側の残存リソースを片付ける。
NS="knowledgebot"

tf() { (cd infra && terraform output -raw "$1"); }

REGION="$(tf region)"
CLUSTER="$(tf cluster_name)"
VPC_ID="$(tf vpc_id)"

echo "[*] Update kubeconfig..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

echo "[*] Delete app-side Kubernetes resources in namespace ${NS}..."
kubectl -n "$NS" delete ingress knowledgebot --ignore-not-found=true
kubectl -n "$NS" delete svc knowledgebot --ignore-not-found=true
kubectl -n "$NS" delete deploy knowledgebot --ignore-not-found=true
kubectl -n "$NS" delete hpa knowledgebot --ignore-not-found=true
kubectl -n "$NS" delete pdb knowledgebot --ignore-not-found=true
kubectl -n "$NS" delete sa knowledgebot-sa --ignore-not-found=true
kubectl -n "$NS" delete configmap knowledgebot-config --ignore-not-found=true
kubectl -n "$NS" delete secret knowledgebot-secrets --ignore-not-found=true

echo "[*] Wait briefly for ALB / target group cleanup to start..."
sleep 20

echo
echo "[*] Remaining resources:"
kubectl -n "$NS" get all,ingress,configmap,secret,serviceaccount 2>/dev/null || true

echo
echo "[*] Remaining ENIs in VPC ${VPC_ID}:"
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NetworkInterfaces[*].{Id:NetworkInterfaceId,Status:Status,Desc:Description}' \
  --output table || true

echo
echo "[*] Remaining Security Groups in VPC ${VPC_ID}:"
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[*].{Id:GroupId,Name:GroupName}' \
  --output table || true

echo
echo "[*] Hint:"
echo "    If ENIs or Security Groups related to ELB remain, wait a few minutes and retry destroy."
echo
echo "[*] Next step:"
echo "    terraform -chdir=infra destroy -var-file=envs/dev.tfvars -auto-approve"
