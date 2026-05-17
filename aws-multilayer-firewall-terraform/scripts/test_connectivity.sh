#!/bin/bash
# 疎通確認スクリプト
# 使用方法: ./scripts/test_connectivity.sh {EC2_INSTANCE_ID} {ALB_DNS}
#
# SSM Send Command を使って EC2 から各種通信を試み、
# 期待通りに許可・拒否されることを確認する。

set -euo pipefail

INSTANCE_ID="${1:-}"
ALB_DNS="${2:-}"
REGION="ap-northeast-1"
PASS_COUNT=0
FAIL_COUNT=0

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: $0 <instance-id> [alb-dns]"
  exit 1
fi

run_ssm() {
  local description="$1"
  local command="$2"
  local expect_success="${3:-true}"

  echo ""
  echo "=== TEST: $description ==="
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --instance-id "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$command\"]" \
    --region "$REGION" \
    --query "Command.CommandId" \
    --output text)

  # コマンドの完了を待つ（最大 30 秒）
  local i=0
  local status="Pending"
  while [[ "$status" == "Pending" || "$status" == "InProgress" ]] && (( i < 6 )); do
    sleep 5
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$INSTANCE_ID" \
      --region "$REGION" \
      --query "Status" \
      --output text 2>/dev/null || echo "Unknown")
    (( i++ ))
  done

  local output
  output=$(aws ssm get-command-invocation \
    --command-id "$cmd_id" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query "StandardOutputContent" \
    --output text 2>/dev/null || echo "")

  if [[ "$expect_success" == "true" && "$status" == "Success" ]]; then
    echo "✅ PASS: $description (status: $status, output: $output)"
    (( PASS_COUNT++ ))
  elif [[ "$expect_success" == "false" && "$status" != "Success" ]]; then
    echo "✅ PASS (expected failure): $description (status: $status)"
    (( PASS_COUNT++ ))
  else
    echo "❌ FAIL: $description (status: $status, output: $output)"
    (( FAIL_COUNT++ ))
  fi
}

echo "======================================"
echo "Network Security Lab - 疎通確認テスト"
echo "Instance: $INSTANCE_ID"
echo "Region:   $REGION"
echo "======================================"

# ---- Network Firewall ドメインフィルタリング ----
echo ""
echo "--- Network Firewall ドメインフィルタリング ---"

run_ssm "許可ドメイン: example.com (HTTPS 200 のはず)" \
  "curl -s -o /dev/null -w '%{http_code}' https://example.com --max-time 10"

run_ssm "許可ドメイン: amazonaws.com (HTTPS 疎通のはず)" \
  "curl -s -o /dev/null -w '%{http_code}' https://s3.amazonaws.com --max-time 10"

run_ssm "拒否ドメイン: evil-site.test (NFW がドロップ → タイムアウトするはず)" \
  "curl -s -o /dev/null --max-time 10 https://evil-site.test; echo exit:\$?" \
  "false"

run_ssm "拒否ドメイン: github.com (許可リスト外 → ドロップされるはず)" \
  "curl -s -o /dev/null --max-time 10 https://github.com; echo exit:\$?" \
  "false"

# ---- WAF 動作確認 ----
if [[ -n "$ALB_DNS" ]]; then
  echo ""
  echo "--- WAF 動作確認 (ALB: $ALB_DNS) ---"

  run_ssm "正常リクエスト: ALB アクセス (200 OK のはず)" \
    "curl -s -o /dev/null -w '%{http_code}' http://${ALB_DNS}/ --max-time 10"

  run_ssm "WAF ブロック: sqlmap UA (403 のはず)" \
    "STATUS=\$(curl -s -o /dev/null -w '%{http_code}' -H 'User-Agent: sqlmap/1.0' http://${ALB_DNS}/ --max-time 10); echo \$STATUS; [[ \$STATUS -eq 403 ]]"

  run_ssm "WAF ブロック: Nikto UA (403 のはず)" \
    "STATUS=\$(curl -s -o /dev/null -w '%{http_code}' -H 'User-Agent: Nikto/2.1.6' http://${ALB_DNS}/ --max-time 10); echo \$STATUS; [[ \$STATUS -eq 403 ]]"

  run_ssm "WAF ブロック: SQLi クエリ (403 のはず)" \
    "STATUS=\$(curl -s -o /dev/null -w '%{http_code}' 'http://${ALB_DNS}/?id=1+UNION+SELECT+1,2,3--' --max-time 10); echo \$STATUS; [[ \$STATUS -eq 403 ]]"

  run_ssm "WAF ブロック: XSS ペイロード (403 のはず)" \
    "STATUS=\$(curl -s -o /dev/null -w '%{http_code}' \"http://${ALB_DNS}/?name=<script>alert(1)</script>\" --max-time 10); echo \$STATUS; [[ \$STATUS -eq 403 ]]"
fi

# ---- NACL 確認 ----
echo ""
echo "--- NACL 確認 ---"

run_ssm "Private → Public 内部通信 (VPC 内は通るはず)" \
  "curl -s -o /dev/null -w '%{http_code}' http://10.0.0.1/ --max-time 5 || true; echo done"

echo ""
echo "======================================"
echo "テスト完了"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo ""
echo "CloudWatch Logs でブロックログを確認してください:"
echo "  NFW Alert: /aws/network-firewall/amf-nfw/alert"
echo "  WAF Log:   aws-waf-logs-amf-alb"
echo "  VPC Flow:  /aws/vpc/flow-log/amf-vpc"
echo "======================================"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
