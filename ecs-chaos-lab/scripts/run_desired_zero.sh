#!/usr/bin/env bash
# シナリオ3: ECS DesiredCount=0 → 全 Task 停止 → 手動復旧確認
# 使い方:
#   ./scripts/run_desired_zero.sh set_zero   # 全 Task 停止
#   ./scripts/run_desired_zero.sh restore    # Service 復旧
# 注意: FIS 実験（desired-zero テンプレート）の起動と、Lambda 直接起動の両方に対応

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
TF_DIR="${PROJECT_ROOT}/terraform/environments/dev"

REGION="ap-northeast-1"
TEMPLATE_ID="${SCENARIO3_TEMPLATE_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-ecl-dev-cluster}"
SERVICE_NAME="${SERVICE_NAME:-ecl-dev-service}"
LAMBDA_NAME="${LAMBDA_FUNCTION_NAME:-ecl-desired-count-changer}"
ACTION="${1:-set_zero}"  # set_zero | restore

# 環境変数未設定時の自動取得（terraform output から）
if [[ -z "$TEMPLATE_ID" ]]; then
  echo "[INFO] SCENARIO3_TEMPLATE_ID が未設定のため terraform output から取得します"
  TEMPLATE_ID=$(cd "$TF_DIR" && terraform output -raw scenario3_template_id)
fi

case "$ACTION" in
  "set_zero")
    echo "========================================"
    echo " シナリオ3: DesiredCount=0 (全 Task 停止)"
    echo " テンプレート: $TEMPLATE_ID"
    echo " クラスター: $CLUSTER_NAME / $SERVICE_NAME"
    echo "========================================"

    PRE_RUNNING=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
      --region "$REGION" \
      --query 'services[0].runningCount' --output text)
    echo "[INFO] 実験前 RunningCount: $PRE_RUNNING"

    echo "[INFO] FIS 実験開始: DesiredCount を 0 に変更..."
    # FIS テンプレート経由で Lambda を起動（実験ログを FIS に記録）
    EXPERIMENT_ID=$(aws fis start-experiment \
      --experiment-template-id "$TEMPLATE_ID" \
      --region "$REGION" \
      --query 'experiment.id' --output text)
    echo "[INFO] 実験 ID: $EXPERIMENT_ID"
    echo ""
    echo "[INFO] ECS Service を監視: ./scripts/watch_service.sh"
    echo "[INFO] 復旧するには: $0 restore"
    echo "[INFO] 実験 ID を保存: export EXPERIMENT_ID=$EXPERIMENT_ID"
    ;;

  "restore")
    echo "========================================"
    echo " シナリオ3: Service 復旧 (DesiredCount=2)"
    echo " Lambda: $LAMBDA_NAME"
    echo "========================================"

    echo "[INFO] Lambda を直接起動して DesiredCount を 2 に復元..."
    # FIS 実験外で Lambda を直接起動（復旧操作）
    aws lambda invoke \
      --function-name "$LAMBDA_NAME" \
      --payload '{"action":"restore"}' \
      --cli-binary-format raw-in-base64-out \
      --region "$REGION" \
      /tmp/lambda_response.json
    echo "[INFO] Lambda レスポンス:"
    cat /tmp/lambda_response.json | jq .

    # Service 安定化を待機
    echo "[INFO] Service の安定化を待機中（最大 5 分）..."
    aws ecs wait services-stable \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --region "$REGION"

    POST_RUNNING=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
      --region "$REGION" \
      --query 'services[0].runningCount' --output text)

    echo ""
    echo "========================================"
    echo " 復旧結果"
    echo "========================================"
    echo " RunningCount: $POST_RUNNING"
    if [[ "${POST_RUNNING:-0}" -ge 2 ]]; then
      echo " ✅ 合格: Service が RunningCount=2 に復旧しました"
    else
      echo " ❌ 要確認: RunningCount が 2 に戻りませんでした"
    fi
    echo " FIS ログ: CloudWatch Logs /aws/fis/ecl-dev"
    echo "========================================"
    ;;

  *)
    echo "[ERROR] 不明なアクション: $ACTION"
    echo "使い方: $0 [set_zero|restore]"
    exit 1
    ;;
esac
