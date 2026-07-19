#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────
# TGWルーティング疎通確認スクリプト
# 期待値:
#   Spoke-A → Hub:     PASS（許可）
#   Spoke-A → Spoke-B: FAIL（禁止）
# ─────────────────────────────────────────

cd "$(dirname "$0")/../envs/ap-northeast-1"

HUB_IP=$(terraform output -raw test_hub_private_ip)
SPOKE_A_ID=$(terraform output -raw test_spoke_a_instance_id)
SPOKE_B_IP=$(terraform output -raw test_spoke_b_private_ip)

echo "=== 疎通確認開始 ==="
echo "Hub IP:     $HUB_IP"
echo "Spoke-B IP: $SPOKE_B_IP"
echo ""

run_ping() {
  local source_instance=$1
  local target_ip=$2
  local label=$3
  local expect_success=$4

  echo -n "[$label] Ping $target_ip from $source_instance ... "

  local command_id
  command_id=$(aws ssm send-command \
    --instance-id "$source_instance" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"ping -c 3 -W 2 $target_ip > /dev/null 2>&1 && echo SUCCESS || echo FAIL\"]" \
    --query 'Command.CommandId' \
    --output text)

  # SSMコマンドの完了を待つ
  sleep 10

  local output
  output=$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$source_instance" \
    --query 'StandardOutputContent' \
    --output text | tr -d '\n')

  if [[ "$output" == "SUCCESS" && "$expect_success" == "true" ]]; then
    echo "PASS（通信OK、期待通り）"
  elif [[ "$output" == "FAIL" && "$expect_success" == "false" ]]; then
    echo "PASS（通信NG、期待通り遮断）"
  elif [[ "$output" == "SUCCESS" && "$expect_success" == "false" ]]; then
    echo "FAIL（通信OK、遮断されるべき）"
    return 1
  else
    echo "FAIL（通信NG、通信できるべき）"
    return 1
  fi
}

FAILED=0

# Spoke-A → Hub（許可されるべき）
run_ping "$SPOKE_A_ID" "$HUB_IP" "Spoke-A → Hub" "true" || FAILED=1

# Spoke-A → Spoke-B（遮断されるべき）
run_ping "$SPOKE_A_ID" "$SPOKE_B_IP" "Spoke-A → Spoke-B" "false" || FAILED=1

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "=== 確認完了: 全テストPASS ==="
else
  echo "=== 確認完了: FAILあり ==="
  exit 1
fi
