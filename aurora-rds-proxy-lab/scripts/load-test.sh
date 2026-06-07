#!/bin/bash
# RDS Proxy の接続プール動作確認
# 大量同時リクエストで Aurora max_connections を超えないことを検証する
# 実行: bash scripts/load-test.sh [ALB_DNS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${1:-}" ]; then
  ALB_DNS="$1"
else
  ALB_DNS=$(cd "$SCRIPT_DIR/../terraform/environments/dev" && terraform output -raw alb_dns_name)
fi
CONCURRENCY=50
TOTAL_REQUESTS=200

echo "=== 負荷テスト: ${CONCURRENCY}並列, ${TOTAL_REQUESTS}リクエスト ==="
echo "対象: http://$ALB_DNS/items"
echo ""

if command -v ab &>/dev/null; then
  # Apache Bench がある場合は精度が高い
  ab -n $TOTAL_REQUESTS -c $CONCURRENCY "http://$ALB_DNS/items"
else
  # curl でバッチ実行
  SUCCESS=0
  ERROR=0
  for i in $(seq 1 $TOTAL_REQUESTS); do
    (
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_DNS/items" || echo "000")
      if [ "$STATUS" = "200" ]; then
        echo "OK"
      else
        echo "ERR:$STATUS"
      fi
    ) &
    # CONCURRENCY ごとに wait して同時接続数を制御
    if (( i % CONCURRENCY == 0 )); then
      wait
      echo "Batch $((i / CONCURRENCY)) 完了 ($i / $TOTAL_REQUESTS)"
    fi
  done
  wait
  echo "全リクエスト完了"
fi

# テスト直後の Aurora 接続数を CloudWatch から取得
# Proxy が max_connections 以内に収めていることを確認する
echo ""
echo "=== Aurora 接続数確認 (直近 5 分の最大値) ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBClusterIdentifier,Value=arpl-aurora-cluster \
  --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Maximum \
  --output table \
  --region ap-northeast-1

echo ""
echo "=== RDS Proxy 接続数確認 ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ClientConnections \
  --dimensions Name=ProxyName,Value=arpl-rds-proxy \
  --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Maximum \
  --output table \
  --region ap-northeast-1
