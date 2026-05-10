#!/usr/bin/env bash
# FIS CPU ストレス実験の起動・監視・結果サマリースクリプト
# 使い方: ./scripts/run_experiment.sh [--dry-run]
#
# 前提: AWS CLI が設定済み、jq がインストール済み
# リージョン: ap-northeast-1

set -euo pipefail

# ============================
# 設定値（terraform output から取得）
# ============================
REGION="ap-northeast-1"
# 実行前に terraform output で確認し、環境変数にセットする
TEMPLATE_ID="${FIS_TEMPLATE_ID:-}"
ASG_NAME="${ASG_NAME:-}"
ALB_DNS="${ALB_DNS:-}"

# バリデーション
if [[ -z "$TEMPLATE_ID" || -z "$ASG_NAME" || -z "$ALB_DNS" ]]; then
  echo "[ERROR] 環境変数が未設定です"
  echo ""
  echo "以下を実行してから再試行してください:"
  echo "  export FIS_TEMPLATE_ID=\$(cd terraform/environments/dev && terraform output -raw fis_experiment_template_id)"
  echo "  export ASG_NAME=\$(cd terraform/environments/dev && terraform output -raw asg_name)"
  echo "  export ALB_DNS=\$(cd terraform/environments/dev && terraform output -raw alb_dns_name)"
  exit 1
fi

DRY_RUN="${1:-}"

echo "================================================"
echo " カオスエンジニアリング実験: CPU ストレス"
echo " テンプレート ID: $TEMPLATE_ID"
echo " 対象 ASG    : $ASG_NAME"
echo " ALB DNS     : $ALB_DNS"
echo "================================================"

# ドライランモード
if [[ "$DRY_RUN" == "--dry-run" ]]; then
  echo ""
  echo "[DRY RUN] 実験は起動しません。設定確認のみ完了。"
  echo ""
  echo "ALB ヘルスチェック確認:"
  curl -sf --max-time 5 "http://$ALB_DNS/health" && echo "[OK] ALB 応答確認" || echo "[WARN] ALB 未応答（インフラ起動前の可能性）"
  exit 0
fi

# ============================
# 実験前の状態を記録
# ============================
echo ""
echo "[INFO] 実験前の状態確認..."

PRE_COUNT=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].Instances | length(@)' \
  --output text)
echo "[INFO] 実験前インスタンス数: $PRE_COUNT"

# ALB ヘルスチェック（任意）
echo "[INFO] ALB ヘルスチェック: http://$ALB_DNS/health"
curl -sf --max-time 5 "http://$ALB_DNS/health" > /dev/null && \
  echo "[INFO] ALB 応答: OK" || \
  echo "[WARN] ALB 未応答"

# ============================
# FIS 実験を起動
# ============================
echo ""
echo "[INFO] FIS 実験を起動中..."
EXPERIMENT_ID=$(aws fis start-experiment \
  --experiment-template-id "$TEMPLATE_ID" \
  --region "$REGION" \
  --query 'experiment.id' \
  --output text)
echo "[INFO] 実験 ID: $EXPERIMENT_ID"

# ============================
# 実験完了まで待機（最大 15 分）
# ============================
MAX_WAIT=900
ELAPSED=0
INTERVAL=30
STATUS=""

echo ""
echo "[INFO] 実験の完了を待機中（最大 ${MAX_WAIT}秒）..."
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATUS=$(aws fis get-experiment \
    --id "$EXPERIMENT_ID" \
    --region "$REGION" \
    --query 'experiment.state.status' \
    --output text)

  echo "[INFO] $(date '+%H:%M:%S') ステータス: $STATUS (経過: ${ELAPSED}秒)"

  if [[ "$STATUS" == "completed" || "$STATUS" == "stopped" || "$STATUS" == "failed" ]]; then
    break
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

# タイムアウト判定
if [[ $ELAPSED -ge $MAX_WAIT && "$STATUS" != "completed" && "$STATUS" != "stopped" && "$STATUS" != "failed" ]]; then
  echo "[WARN] タイムアウト: 実験が ${MAX_WAIT}秒 以内に完了しませんでした"
  STATUS="timeout"
fi

# ============================
# 実験後の状態確認
# ============================
POST_COUNT=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].Instances | length(@)' \
  --output text)

# ============================
# 結果サマリー
# ============================
echo ""
echo "================================================"
echo " 実験結果サマリー"
echo "================================================"
echo " 実験 ID        : $EXPERIMENT_ID"
echo " 最終ステータス : $STATUS"
echo " 実験前インスタンス数: $PRE_COUNT"
echo " 実験後インスタンス数: $POST_COUNT"

if [[ $POST_COUNT -gt $PRE_COUNT ]]; then
  echo " [SUCCESS] スケールアウト成功！($PRE_COUNT -> $POST_COUNT インスタンス)"
else
  echo " [WARN] スケールアウトが確認できませんでした ($PRE_COUNT -> $POST_COUNT)"
  echo "        CloudWatch メトリクスと FIS ログを確認してください"
fi

echo ""
echo " FIS ログ          : CloudWatch Logs /aws/fis/cel-dev-cpu-stress"
echo " ALB エンドポイント: http://$ALB_DNS/health"
echo ""
echo " 詳細確認コマンド:"
echo "   aws fis get-experiment --id $EXPERIMENT_ID --region $REGION"
echo "================================================"

# 実験 ID をファイルに保存（Runbook の後続ステップで参照可能）
echo "$EXPERIMENT_ID" > .last_experiment_id
echo "[INFO] 実験 ID を .last_experiment_id に保存しました"
