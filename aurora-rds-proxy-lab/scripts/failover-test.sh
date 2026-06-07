#!/bin/bash
# Aurora フェイルオーバー時のアプリ影響を計測する
# RDS Proxy 経由の場合、エンドポイント変更なしでフェイルオーバーが透過される
# 実行: bash scripts/failover-test.sh [ALB_DNS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_PID=""

cleanup() {
  [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null || true
}
trap cleanup EXIT

ALB_DNS=${1:-""}
if [ -z "$ALB_DNS" ]; then
  ALB_DNS=$(cd "$SCRIPT_DIR/../terraform/environments/dev" && terraform output -raw alb_dns_name)
fi

echo "=== フェイルオーバーテスト開始 ==="
echo "ALB: http://$ALB_DNS"
echo ""

RESULT_FILE="/tmp/failover-results-$(date +%s).txt"
SUCCESS=0
ERROR=0
TOTAL=0

monitor_requests() {
  while true; do
    START=$(date +%s%N)
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 \
      "http://$ALB_DNS/health" 2>/dev/null || echo "000")
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000000 ))

    TIMESTAMP=$(date '+%H:%M:%S')
    if [ "$HTTP_STATUS" = "200" ]; then
      echo "[$TIMESTAMP] OK (${LATENCY}ms)" | tee -a "$RESULT_FILE"
      (( SUCCESS++ )) || true
    else
      echo "[$TIMESTAMP] ERROR: HTTP $HTTP_STATUS (${LATENCY}ms)" | tee -a "$RESULT_FILE"
      (( ERROR++ )) || true
    fi
    (( TOTAL++ )) || true
    sleep 2
  done
}

# バックグラウンドでモニタリング開始
monitor_requests &
MONITOR_PID=$!

# 10秒ベースライン計測後にフェイルオーバーを実施
sleep 10

echo ""
echo "=== Aurora フェイルオーバー実行 ==="
FAILOVER_START=$(date '+%H:%M:%S')
aws rds failover-db-cluster \
  --db-cluster-identifier arpl-aurora-cluster \
  --region ap-northeast-1
echo "フェイルオーバー開始: $FAILOVER_START"

echo "フェイルオーバー完了を待機中 (通常 20〜40 秒)..."
aws rds wait db-cluster-available \
  --db-cluster-identifier arpl-aurora-cluster \
  --region ap-northeast-1
FAILOVER_END=$(date '+%H:%M:%S')
echo "フェイルオーバー完了: $FAILOVER_END"

# フェイルオーバー後 30 秒間の回復状況を計測
sleep 30

kill $MONITOR_PID 2>/dev/null || true

echo ""
echo "=== テスト結果 ==="
echo "成功: $SUCCESS リクエスト"
echo "エラー: $ERROR リクエスト"
echo "合計: $TOTAL リクエスト"
if [ "$TOTAL" -gt 0 ]; then
  echo "エラー率: $(echo "scale=1; $ERROR * 100 / $TOTAL" | bc)%"
fi
echo "詳細ログ: $RESULT_FILE"
echo ""
echo "=== Writer/Reader の役割確認 ==="
aws rds describe-db-cluster \
  --db-cluster-identifier arpl-aurora-cluster \
  --query 'DBCluster.DBClusterMembers[*].{InstanceID:DBInstanceIdentifier,IsWriter:IsClusterWriter}' \
  --output table \
  --region ap-northeast-1
