#!/usr/bin/env bash
# =============================================================
# 観測基盤セットアップ一括スクリプト
# Container Insights + ADOT + AMPの接続を設定する
#
# 前提: terraform apply（observabilityモジュール含む）完了済み
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

echo "📊 観測基盤セットアップ開始: ${CLUSTER_NAME}"
echo ""

# 1. Container Insights 有効化
echo "=== Step 1/4: Container Insights 有効化 ==="
"${SCRIPT_DIR}/enable_container_insights.sh" "${CLUSTER_NAME}"

# 2. ADOT Operator インストール（EKSアドオン）
echo ""
echo "=== Step 2/4: ADOT Operator インストール ==="
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name adot \
  --region "${REGION}" \
  2>/dev/null || echo "ADOTアドオンは既にインストール済みです"

echo "⏳ ADOT Operator起動待機..."
aws eks wait addon-active \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name adot \
  --region "${REGION}" \
  2>/dev/null || true

# 3. TerraformアウトプットからAMP・ADOTの値を取得してマニフェストに反映
echo ""
echo "=== Step 3/4: ADOTコレクター設定 ==="
AMP_URL=$(cd "${PROJECT_ROOT}/terraform" && terraform output -raw amp_remote_write_url)
ADOT_ROLE=$(cd "${PROJECT_ROOT}/terraform" && terraform output -raw adot_role_arn)

echo "AMP Remote Write URL: ${AMP_URL}"
echo "ADOT Role ARN: ${ADOT_ROLE}"

# プレースホルダーを実際の値に置換（元ファイルは変更しない）
MANIFEST_TMP=$(mktemp)
sed \
  -e "s|ADOT_ROLE_ARN|${ADOT_ROLE}|g" \
  -e "s|AMP_REMOTE_WRITE_URL|${AMP_URL}|g" \
  "${PROJECT_ROOT}/k8s/monitoring/adot-collector.yaml" > "${MANIFEST_TMP}"

# 4. ADOTコレクターをデプロイ
echo ""
echo "=== Step 4/4: ADOTコレクター デプロイ ==="
kubectl apply -f "${MANIFEST_TMP}"
rm -f "${MANIFEST_TMP}"

echo "⏳ ADOTコレクター起動待機（最大5分）..."
kubectl rollout status deployment/adot-collector-collector \
  -n amazon-metrics --timeout=300s 2>/dev/null || \
  kubectl get pods -n amazon-metrics

echo ""
echo "✅ 観測基盤セットアップ完了"
echo ""
echo "============================================"
echo "Grafana URL:"
cd "${PROJECT_ROOT}/terraform" && terraform output -raw grafana_endpoint
echo ""
echo "============================================"
echo ""
echo "次のステップ:"
echo "  1. 上記URLにAWS SSOでログイン"
echo "  2. Configuration → Data Sources → Add data source → Prometheus"
echo "     URL: $(cd "${PROJECT_ROOT}/terraform" && terraform output -raw amp_query_endpoint)"
echo "  3. Dashboards → Import → k8s/monitoring/grafana-dashboard-configmap.yaml の dashboard.json を貼り付け"
echo "  4. FIS実験実行後にリアルタイム確認:"
echo "     ./fis/run_experiment.sh az-outage"
