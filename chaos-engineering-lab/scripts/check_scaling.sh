#!/usr/bin/env bash
# ASG スケールアウト状態をリアルタイム監視するスクリプト
# 使い方: ./scripts/check_scaling.sh [監視間隔秒数(デフォルト30)]
#
# watch コマンドと組み合わせて使う:
#   watch -n 30 ./scripts/check_scaling.sh

set -euo pipefail

REGION="ap-northeast-1"
ASG_NAME="${ASG_NAME:-}"
INTERVAL="${1:-30}"

if [[ -z "$ASG_NAME" ]]; then
  echo "[ERROR] ASG_NAME 環境変数を設定してください"
  echo "  export ASG_NAME=\$(cd terraform/environments/dev && terraform output -raw asg_name)"
  exit 1
fi

echo "=== ASG スケーリング状態: $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "    ASG 名: $ASG_NAME"
echo ""

# ASG の現在状態を取得
ASG_INFO=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0]')

DESIRED=$(echo "$ASG_INFO" | jq -r '.DesiredCapacity')
MIN=$(echo "$ASG_INFO" | jq -r '.MinSize')
MAX=$(echo "$ASG_INFO" | jq -r '.MaxSize')
INSTANCES=$(echo "$ASG_INFO" | jq -r '.Instances | length')

echo "  [容量]"
echo "  最小 / 希望 / 最大: $MIN / $DESIRED / $MAX"
echo "  実際のインスタンス数: $INSTANCES"
echo ""

# 各インスタンスの状態
echo "  [インスタンス詳細]"
INSTANCE_LIST=$(echo "$ASG_INFO" | jq -r '.Instances[] | "  - \(.InstanceId) | \(.LifecycleState) | \(.HealthStatus)"')
if [[ -z "$INSTANCE_LIST" ]]; then
  echo "  (インスタンスなし)"
else
  echo "$INSTANCE_LIST"
fi

# 直近のスケーリングアクティビティ（5件）
echo ""
echo "  [直近のスケーリングアクティビティ（最大5件）]"
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "$ASG_NAME" \
  --max-records 5 \
  --region "$REGION" \
  --query 'Activities[*].{Time:StartTime,Status:StatusCode,Cause:Cause}' \
  --output table 2>/dev/null || echo "  (アクティビティなし)"

# CPU メトリクスの直近値（CloudWatch から取得）
echo ""
echo "  [CPU 使用率（直近 5 分の平均）]"
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -d "5 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
             date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ")

CPU_AVG=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 300 \
  --statistics Average \
  --region "$REGION" \
  --query 'Datapoints[0].Average' \
  --output text 2>/dev/null || echo "N/A")

echo "  CPUUtilization (ASG 平均): ${CPU_AVG}%"
echo ""
echo "  次回更新まで ${INTERVAL}秒 （watch -n ${INTERVAL} で自動更新）"
