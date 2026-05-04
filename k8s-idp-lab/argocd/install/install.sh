#!/bin/bash
set -e

# ArgoCD namespace 作成
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# ArgoCD インストール
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# argocd-server の Deployment が存在するまで待つ（apply 直後はリソースがまだない場合がある）
echo "Waiting for ArgoCD deployments to be created..."
sleep 10

# ArgoCD の全 Pod が Ready になるまで待つ（タイムアウト 5 分）
echo "Waiting for ArgoCD pods to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/part-of=argocd \
  -n argocd \
  --timeout=300s

echo ""
echo "ArgoCD installed successfully."
echo ""
echo "Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "Access ArgoCD UI: http://localhost:30080"
echo "Username: admin"
