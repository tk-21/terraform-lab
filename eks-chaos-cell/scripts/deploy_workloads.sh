#!/usr/bin/env bash
# =============================================================
# 全Cellワークロードのデプロイ
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s"

echo "==> ワークロードデプロイ開始"

# kubeconfig 確認・更新
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}"

# Cell-A デプロイ
echo "==> Cell-A デプロイ..."
kubectl apply -f "${K8S_DIR}/cells/cell-a/"

# Cell-B デプロイ
echo "==> Cell-B デプロイ..."
kubectl apply -f "${K8S_DIR}/cells/cell-b/"

# Ingress デプロイ
echo "==> Ingress デプロイ..."
kubectl apply -f "${K8S_DIR}/ingress/alb-ingress.yaml"

# 起動待機
echo "==> Pod起動待機..."
kubectl rollout status deployment/app -n cell-a --timeout=300s
kubectl rollout status deployment/app -n cell-b --timeout=300s

echo ""
echo "=== Pod確認 ==="
kubectl get pods -n cell-a -o wide
echo ""
kubectl get pods -n cell-b -o wide

echo ""
echo "=== PDB確認 ==="
kubectl get pdb -n cell-a
kubectl get pdb -n cell-b

echo ""
echo "=== ノード確認（Cellラベル付き）==="
kubectl get nodes --label-columns=cell,topology.kubernetes.io/zone

echo ""
echo "=== Ingress確認（ALB URL取得に1-3分かかります）==="
kubectl get ingress -n cell-a

echo ""
echo "==> デプロイ完了"
echo ""
echo "ALB URL確認コマンド:"
echo "  kubectl get ingress chaos-cell-ingress -n cell-a -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
