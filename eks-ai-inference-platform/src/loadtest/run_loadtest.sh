#!/usr/bin/env bash
# 負荷試験を3段階で実行するスクリプト
# 実行前に ALB_URL 環境変数を設定すること: export ALB_URL=xxx.ap-northeast-1.elb.amazonaws.com
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}"

if [[ -z "${ALB_URL:-}" ]]; then
  echo "ERROR: ALB_URL が設定されていません"
  echo "  export ALB_URL=\$(terraform -chdir=../../terraform/environments/dev output -raw alb_dns_name)"
  exit 1
fi

echo "=== Step 1: 軽負荷 (5ユーザー) - vLLMベースライン ==="
locust \
  --host="https://${ALB_URL}" \
  --users 5 --spawn-rate 1 --run-time 5m \
  --headless --only-summary \
  --csv="${RESULTS_DIR}/vllm-baseline"

echo "=== Step 2: 中負荷 (20ユーザー) - KEDAスケールアウト確認 ==="
locust \
  --host="https://${ALB_URL}" \
  --users 20 --spawn-rate 2 --run-time 10m \
  --headless --only-summary \
  --csv="${RESULTS_DIR}/keda-scaleout"

echo "=== Step 3: 高負荷 (50ユーザー) - Bedrockフォールバック確認 ==="
locust \
  --host="https://${ALB_URL}" \
  --users 50 --spawn-rate 5 --run-time 10m \
  --headless --only-summary \
  --csv="${RESULTS_DIR}/bedrock-fallback"

echo ""
echo "=== 負荷試験完了 ==="
echo "結果ファイル: ${RESULTS_DIR}/"
ls -la "${RESULTS_DIR}/"
