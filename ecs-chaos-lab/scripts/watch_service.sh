#!/usr/bin/env bash
# ECS Service 状態をリアルタイム監視（全シナリオ共通）
# 使い方: ./scripts/watch_service.sh
# 別ターミナルで実行し、実験スクリプトと並行して状態確認する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
TF_DIR="${PROJECT_ROOT}/terraform/environments/dev"

REGION="ap-northeast-1"
CLUSTER_NAME="${CLUSTER_NAME:-ecl-dev-cluster}"
SERVICE_NAME="${SERVICE_NAME:-ecl-dev-service}"
ALB_DNS="${ALB_DNS:-}"

# ALB_DNS が未設定の場合は terraform output から取得を試みる
if [[ -z "$ALB_DNS" ]]; then
  ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name 2>/dev/null || echo "")
fi

echo "[INFO] 監視開始: $CLUSTER_NAME / $SERVICE_NAME (Ctrl+C で停止)"
echo ""

while true; do
  clear
  echo "=== ECS Service 監視: $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo ""

  SVC=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0]')

  DESIRED=$(echo "$SVC" | jq -r '.desiredCount')
  RUNNING=$(echo "$SVC" | jq -r '.runningCount')
  PENDING=$(echo "$SVC" | jq -r '.pendingCount')
  STATUS=$(echo "$SVC" | jq -r '.status')

  echo "  Status       : $STATUS"
  echo "  DesiredCount : $DESIRED"
  echo "  RunningCount : $RUNNING"
  echo "  PendingCount : $PENDING"
  echo ""

  if [[ -n "$ALB_DNS" ]]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://$ALB_DNS/health" 2>/dev/null || echo "ERR")
    echo "  ALB /health  : HTTP $HTTP_CODE"
    echo ""
  fi

  echo "  直近のイベント（上位5件）:"
  echo "$SVC" | jq -r '.events[:5][] | "  [\(.createdAt | split(".")[0])] \(.message)"'

  sleep 10
done
