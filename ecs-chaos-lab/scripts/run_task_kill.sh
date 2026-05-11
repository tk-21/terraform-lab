#!/usr/bin/env bash
# シナリオ1: ECS Task 強制停止 → Service 自己回復確認
# 使い方: ./scripts/run_task_kill.sh [--dry-run]
# 前提: AWS CLI / jq インストール済み、環境変数設定済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
TF_DIR="${PROJECT_ROOT}/terraform/environments/dev"

REGION="ap-northeast-1"
TEMPLATE_ID="${SCENARIO1_TEMPLATE_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-ecl-dev-cluster}"
SERVICE_NAME="${SERVICE_NAME:-ecl-dev-service}"
ALB_DNS="${ALB_DNS:-}"

# 環境変数未設定時の自動取得（terraform output から）
if [[ -z "$TEMPLATE_ID" ]]; then
  echo "[INFO] SCENARIO1_TEMPLATE_ID が未設定のため terraform output から取得します"
  TEMPLATE_ID=$(cd "$TF_DIR" && terraform output -raw scenario1_template_id)
fi

if [[ -z "$ALB_DNS" ]]; then
  ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name)
fi

DRY_RUN="${1:-}"

echo "========================================"
echo " シナリオ1: ECS Task 強制停止"
echo " テンプレート: $TEMPLATE_ID"
echo " クラスター: $CLUSTER_NAME / $SERVICE_NAME"
echo "========================================"

[[ "$DRY_RUN" == "--dry-run" ]] && echo "[DRY RUN] 終了" && exit 0

# 実験前の状態を記録
PRE_RUNNING=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$REGION" \
  --query 'services[0].runningCount' --output text)
echo "[INFO] 実験前 RunningCount: $PRE_RUNNING"

# FIS 実験開始
echo "[INFO] FIS 実験を起動..."
EXPERIMENT_ID=$(aws fis start-experiment \
  --experiment-template-id "$TEMPLATE_ID" \
  --region "$REGION" \
  --query 'experiment.id' --output text)
echo "[INFO] 実験 ID: $EXPERIMENT_ID"

# 実験完了を待機（最大 10 分）
MAX_WAIT=600; ELAPSED=0; INTERVAL=20
STATUS=""
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATUS=$(aws fis get-experiment --id "$EXPERIMENT_ID" \
    --region "$REGION" \
    --query 'experiment.state.status' --output text)

  RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].runningCount' --output text)

  echo "[$(date '+%H:%M:%S')] FIS: $STATUS | RunningCount: $RUNNING"

  [[ "$STATUS" =~ ^(completed|stopped|failed)$ ]] && break
  sleep $INTERVAL; ELAPSED=$((ELAPSED + INTERVAL))
done

# 実験後の状態確認（復旧まで最大 3 分待機）
echo "[INFO] Service 復旧を待機中（最大 3 分）..."
RECOVERY_ELAPSED=0
POST_RUNNING=0
while [[ $RECOVERY_ELAPSED -lt 180 ]]; do
  POST_RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].runningCount' --output text)
  [[ "$POST_RUNNING" -ge 2 ]] && break
  sleep 15; RECOVERY_ELAPSED=$((RECOVERY_ELAPSED + 15))
  echo "[$(date '+%H:%M:%S')] 復旧待機中... RunningCount: $POST_RUNNING"
done

echo ""
echo "========================================"
echo " 実験結果サマリー"
echo "========================================"
echo " 実験 ID: $EXPERIMENT_ID"
echo " 最終ステータス: $STATUS"
echo " 実験前 RunningCount: $PRE_RUNNING"
echo " 実験後 RunningCount: $POST_RUNNING"
echo " 復旧時間: 約 ${RECOVERY_ELAPSED} 秒"
echo ""
if [[ "${POST_RUNNING:-0}" -ge 2 ]]; then
  echo " ✅ 合格: Service が $RECOVERY_ELAPSED 秒以内に RunningCount=2 に復旧"
else
  echo " ❌ 要確認: RunningCount が 2 に戻りませんでした"
  echo "    ECS Events: aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME"
fi
echo " ALB: http://$ALB_DNS/health"
echo " FIS ログ: CloudWatch Logs /aws/fis/ecl-dev"
echo "========================================"
