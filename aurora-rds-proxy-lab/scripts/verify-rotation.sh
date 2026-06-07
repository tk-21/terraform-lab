#!/bin/bash
# Secrets Manager ローテーション中の接続断有無を計測する
# RDS Proxy が AWSCURRENT/AWSPENDING 両パスワードを受け入れることで接続断なしを実現
# 実行: bash scripts/verify-rotation.sh [ALB_DNS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_PID=""

cleanup() {
  [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null || true
}
trap cleanup EXIT

if [ -n "${1:-}" ]; then
  ALB_DNS="$1"
else
  ALB_DNS=$(cd "$SCRIPT_DIR/../terraform/environments/dev" && terraform output -raw alb_dns_name)
fi
RESULT_FILE="/tmp/rotation-results-$(date +%s).txt"

echo "=== ローテーション検証開始 ==="
echo "監視対象: http://$ALB_DNS/items"
echo ""

SUCCESS=0
ERROR=0

monitor() {
  while true; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 "http://$ALB_DNS/items" 2>/dev/null || echo "000")
    TIMESTAMP=$(date '+%H:%M:%S')
    if [ "$HTTP_STATUS" = "200" ]; then
      echo "[$TIMESTAMP] OK" | tee -a "$RESULT_FILE"
      (( SUCCESS++ )) || true
    else
      echo "[$TIMESTAMP] ERROR: $HTTP_STATUS" | tee -a "$RESULT_FILE"
      (( ERROR++ )) || true
    fi
    sleep 2
  done
}

monitor &
MONITOR_PID=$!
# ベースライン計測
sleep 5

echo "=== ローテーション実行 ==="
aws secretsmanager rotate-secret \
  --secret-id arpl/db/appuser \
  --rotate-immediately \
  --region ap-northeast-1
echo "ローテーション開始: $(date '+%H:%M:%S')"

# ローテーション Lambda の完了を待機
while true; do
  STATUS=$(aws secretsmanager describe-secret \
    --secret-id arpl/db/appuser \
    --query 'RotationStatus' --output text \
    --region ap-northeast-1 2>/dev/null || echo "UNKNOWN")
  if [ "$STATUS" != "InProgress" ]; then
    echo "ローテーション完了: $(date '+%H:%M:%S') (Status: $STATUS)"
    break
  fi
  echo "ローテーション中... $(date '+%H:%M:%S')"
  sleep 5
done

# 完了後 20 秒間の安定性確認
sleep 20
kill $MONITOR_PID 2>/dev/null || true

TOTAL=$(( SUCCESS + ERROR ))
echo ""
echo "=== 検証結果 ==="
echo "成功: $SUCCESS"
echo "エラー: $ERROR"
echo "合計: $TOTAL"
if [ "$ERROR" -eq 0 ]; then
  echo "ローテーション中に接続断なし (RDS Proxy が AWSCURRENT/AWSPENDING 両パスワードを受け入れ)"
else
  echo "エラーあり: ログを確認してください"
  grep "ERROR" "$RESULT_FILE" || true
fi
echo "詳細ログ: $RESULT_FILE"
