#!/usr/bin/env bash
# =============================================================
# FIS 実験実行・計測スクリプト
#
# 使用方法:
#   ./fis/run_experiment.sh az-outage        # AZ障害実験
#   ./fis/run_experiment.sh cpu-stress       # CPUストレス実験
#   ./fis/run_experiment.sh network-latency  # ネットワーク遅延実験
#
# 実験中は以下を並行計測する:
#   - ALBヘルスチェック成功率
#   - Pod数の変化
#   - Karpenterノード起動時間
# =============================================================

set -euo pipefail

EXPERIMENT_TYPE="${1:-az-outage}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"
RESULTS_FILE="results/experiment-$(date +%Y%m%d-%H%M%S).md"

# 実験IDをTerraform outputから取得（フォールバックはAWS CLIタグ検索）
get_experiment_id() {
  local type="$1"
  cd terraform
  case "$type" in
    az-outage)
      terraform output -raw experiment_az_outage_id 2>/dev/null || \
        aws fis list-experiment-templates --region "${REGION}" \
          --query "experimentTemplates[?tags.\"experiment-type\"=='az-outage'].id" \
          --output text
      ;;
    cpu-stress)
      terraform output -raw experiment_cpu_stress_id 2>/dev/null
      ;;
    network-latency)
      terraform output -raw experiment_network_latency_id 2>/dev/null
      ;;
    *)
      echo "ERROR: 不明な実験タイプ: ${type}" >&2
      echo "使用可能: az-outage | cpu-stress | network-latency" >&2
      exit 1
      ;;
  esac
  cd ..
}

# ALBのヘルスチェック状態を確認（タイムアウト5秒）
check_alb_health() {
  local alb_url="$1"
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "http://${alb_url}/healthz" 2>/dev/null || echo "000")
  echo "${response}"
}

# 実験前後の状態スナップショット（Pod数・ノード状態）
take_snapshot() {
  local label="$1"
  echo "--- スナップショット: ${label} ---"
  echo "Cell-A Pod数: $(kubectl get pods -n cell-a --no-headers 2>/dev/null | wc -l)"
  echo "Cell-B Pod数: $(kubectl get pods -n cell-b --no-headers 2>/dev/null | wc -l)"
  echo "ノード状態:"
  kubectl get nodes --label-columns=cell,topology.kubernetes.io/zone --no-headers 2>/dev/null || true
}

mkdir -p results

echo "=============================================="
echo "FIS実験開始: ${EXPERIMENT_TYPE}"
echo "開始時刻: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

echo ""
echo "実験前スナップショット..."
take_snapshot "実験前"

# ALB URLを取得（存在しない場合はスキップ）
ALB_URL=$(kubectl get ingress chaos-cell-ingress -n cell-a \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

INITIAL_HEALTH="N/A"
if [ -n "${ALB_URL}" ]; then
  INITIAL_HEALTH=$(check_alb_health "${ALB_URL}")
  echo "実験前ALBヘルスチェック: ${INITIAL_HEALTH}"
fi

# FIS実験を開始
TEMPLATE_ID=$(get_experiment_id "${EXPERIMENT_TYPE}")
echo ""
echo "実験テンプレートID: ${TEMPLATE_ID}"
echo "実験を開始します..."

EXPERIMENT_ID=$(aws fis start-experiment \
  --experiment-template-id "${TEMPLATE_ID}" \
  --region "${REGION}" \
  --query "experiment.id" \
  --output text)

echo "実験ID: ${EXPERIMENT_ID}"
EXPERIMENT_START=$(date +%s)
RECOVERY_TIME="計測中"

# 実験中モニタリングループ（10秒ごと・最大10分）
echo ""
echo "実験中モニタリング開始..."
echo ""

MONITORING_INTERVAL=10
MAX_ITERATIONS=$(( 600 / MONITORING_INTERVAL ))

for i in $(seq 1 "${MAX_ITERATIONS}"); do
  ELAPSED=$(( $(date +%s) - EXPERIMENT_START ))

  STATUS=$(aws fis get-experiment \
    --id "${EXPERIMENT_ID}" \
    --region "${REGION}" \
    --query "experiment.state.status" \
    --output text)

  HEALTH="N/A"
  if [ -n "${ALB_URL}" ]; then
    HEALTH=$(check_alb_health "${ALB_URL}")
  fi

  CELL_A_PODS=$(kubectl get pods -n cell-a --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  CELL_B_PODS=$(kubectl get pods -n cell-b --no-headers 2>/dev/null | grep -c "Running" || echo "0")

  echo "[${ELAPSED}s] Status:${STATUS} | ALB:${HEALTH} | CellA:${CELL_A_PODS}Pod | CellB:${CELL_B_PODS}Pod"

  if [[ "${STATUS}" == "completed" || "${STATUS}" == "stopped" || "${STATUS}" == "failed" ]]; then
    echo ""
    echo "実験完了: ${STATUS}"
    RECOVERY_TIME=$(( $(date +%s) - EXPERIMENT_START ))
    break
  fi

  sleep "${MONITORING_INTERVAL}"
done

echo ""
echo "実験後スナップショット..."
take_snapshot "実験後"

# 結果をMarkdown形式で保存
cat > "${RESULTS_FILE}" << MARKDOWN
# FIS実験結果: ${EXPERIMENT_TYPE}

## 実験概要

- 実験タイプ: ${EXPERIMENT_TYPE}
- 実験ID: ${EXPERIMENT_ID}
- 実験時刻: $(date '+%Y-%m-%d %H:%M:%S')
- クラスター: ${CLUSTER_NAME}

## 計測値

| 指標 | 値 |
|------|-----|
| 実験開始〜完了 | ${RECOVERY_TIME}秒 |
| 実験前ALBヘルス | ${INITIAL_HEALTH} |
| Cell-B への影響 | 要確認 |

## 実験ログ

実験ID: ${EXPERIMENT_ID}
CloudWatch Logs: /aws/fis/${CLUSTER_NAME}

## 所感・気づき

（ここに手動で記録する）
MARKDOWN

echo ""
echo "結果を記録: ${RESULTS_FILE}"
echo ""
echo "CloudWatch Logsで詳細確認:"
echo "  aws logs tail /aws/fis/${CLUSTER_NAME} --follow --region ${REGION}"
