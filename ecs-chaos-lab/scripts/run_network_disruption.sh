#!/usr/bin/env bash
# シナリオ2: ECS Task ネットワーク遮断 → ALB Unhealthy 切り離し → 自動復旧確認
# 使い方: ./scripts/run_network_disruption.sh [--dry-run]
# 前提: AWS CLI / jq / curl インストール済み、環境変数設定済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
TF_DIR="${PROJECT_ROOT}/terraform/environments/dev"

REGION="ap-northeast-1"
TEMPLATE_ID="${SCENARIO2_TEMPLATE_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-ecl-dev-cluster}"
SERVICE_NAME="${SERVICE_NAME:-ecl-dev-service}"
ALB_DNS="${ALB_DNS:-}"

# 環境変数未設定時の自動取得（terraform output から）
if [[ -z "$TEMPLATE_ID" ]]; then
  echo "[INFO] SCENARIO2_TEMPLATE_ID が未設定のため terraform output から取得します"
  TEMPLATE_ID=$(cd "$TF_DIR" && terraform output -raw scenario2_template_id)
fi

if [[ -z "$ALB_DNS" ]]; then
  ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name)
fi

DRY_RUN="${1:-}"

echo "========================================"
echo " シナリオ2: ネットワーク遮断"
echo " テンプレート: $TEMPLATE_ID"
echo " クラスター: $CLUSTER_NAME / $SERVICE_NAME"
echo "========================================"

[[ "$DRY_RUN" == "--dry-run" ]] && echo "[DRY RUN] 終了" && exit 0

# 実験前の ALB 状態を確認
PRE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$ALB_DNS/health" || echo "ERR")
echo "[INFO] 実験前 ALB HTTP: $PRE_HTTP"

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
echo "[INFO] ALB レスポンスを監視中（FIS 実験中は 503 が期待値）..."

# 実験完了を待機（最大 10 分）、ALB レスポンスも並行して監視
MAX_WAIT=600; ELAPSED=0; INTERVAL=15
STATUS=""
SAW_503=false
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATUS=$(aws fis get-experiment --id "$EXPERIMENT_ID" \
    --region "$REGION" \
    --query 'experiment.state.status' --output text)

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$ALB_DNS/health" || echo "ERR")

  RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].runningCount' --output text)

  echo "[$(date '+%H:%M:%S')] FIS: $STATUS | HTTP: $HTTP_CODE | RunningCount: $RUNNING"

  [[ "$HTTP_CODE" == "503" ]] && SAW_503=true

  [[ "$STATUS" =~ ^(completed|stopped|failed)$ ]] && break
  sleep $INTERVAL; ELAPSED=$((ELAPSED + INTERVAL))
done

echo "[INFO] FIS 実験終了: $STATUS"
echo "[INFO] ALB が Healthy に戻るまで最大 2 分待機..."

# ALB が Healthy に戻るまで待機
RECOVERY_ELAPSED=0
FINAL_HTTP=""
for i in $(seq 1 8); do
  FINAL_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$ALB_DNS/health" || echo "ERR")
  echo "[$(date '+%H:%M:%S')] HTTP: $FINAL_HTTP"
  if [[ "$FINAL_HTTP" == "200" ]]; then
    echo "✅ 復旧確認"
    break
  fi
  RECOVERY_ELAPSED=$((RECOVERY_ELAPSED + 15))
  sleep 15
done

echo ""
echo "========================================"
echo " 実験結果サマリー"
echo "========================================"
echo " 実験 ID: $EXPERIMENT_ID"
echo " 最終ステータス: $STATUS"
echo " 実験前 HTTP: $PRE_HTTP"
echo " 実験中 503 発生: $SAW_503"
echo " 実験後 HTTP: $FINAL_HTTP"
echo " 復旧待機時間: 約 ${RECOVERY_ELAPSED} 秒"
echo ""
if [[ "$SAW_503" == "true" && "$FINAL_HTTP" == "200" ]]; then
  echo " ✅ 合格: 遮断中に HTTP 503 を観測し、実験終了後に 200 に復旧"
elif [[ "$SAW_503" == "false" ]]; then
  echo " ⚠️  要確認: HTTP 503 が観測されませんでした（遮断が機能しているか確認）"
  echo "    ALB TargetGroup HealthyHostCount を確認してください"
else
  echo " ❌ 要確認: 実験後も HTTP 200 に復旧しませんでした"
fi
echo " ALB: http://$ALB_DNS/health"
echo " FIS ログ: CloudWatch Logs /aws/fis/ecl-dev"
echo "========================================"
