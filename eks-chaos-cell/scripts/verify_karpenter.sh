#!/usr/bin/env bash
# Karpenter導入後の動作確認スクリプト
set -euo pipefail

echo "📋 Karpenter Pod確認..."
kubectl get pods -n karpenter

echo ""
echo "📋 EC2NodeClass確認..."
kubectl get ec2nodeclass

echo ""
echo "📋 NodePool確認..."
kubectl get nodepool

echo ""
echo "📋 既存ノード確認..."
kubectl get nodes --show-labels | grep -E "NAME|cell|system"

echo ""
echo "🧪 Karpenterスケールテスト（Cell-A）..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: karpenter-test-cell-a
  namespace: default
spec:
  nodeSelector:
    cell: cell-a
  tolerations:
    - key: cell
      value: cell-a
      effect: NoSchedule
  containers:
    - name: test
      image: public.ecr.aws/amazonlinux/amazonlinux:2
      command: ["sleep", "60"]
      resources:
        requests:
          cpu: "1"
          memory: "512Mi"
EOF

echo "Pod作成済み。Karpenterがノードを起動するまで待機（最大300秒）..."
kubectl wait --for=condition=Ready pod/karpenter-test-cell-a --timeout=300s

echo ""
echo "✅ Cell-A ノード起動確認"
echo "ノードのAZラベル確認..."
NODE=$(kubectl get pod karpenter-test-cell-a -o jsonpath='{.spec.nodeName}')
kubectl get node "${NODE}" --show-labels | grep -E "topology.kubernetes.io/zone|cell"

# クリーンアップ
kubectl delete pod karpenter-test-cell-a

echo ""
echo "✅ Karpenter動作確認完了"
