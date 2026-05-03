#!/usr/bin/env bash
# =============================================================
# verify.sh — lsyncd 同期動作確認スクリプト
# Usage: bash scripts/verify.sh
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
KEY_PATH="$PROJECT_ROOT/ansible/keys/ec2_key.pem"
DELAY=7  # lsyncd_delay(5秒) + バッファ(2秒)

# terraform output から IP を取得
MASTER_IP=$(cd "$PROJECT_ROOT/terraform" && terraform output -raw master_public_ip)
SLAVE_IPS=$(cd "$PROJECT_ROOT/terraform" && terraform output -json slave_public_ips | python3 -c "import sys,json; [print(ip) for ip in json.load(sys.stdin)]")

echo "=============================="
echo "lsyncd 動作確認"
echo "=============================="
echo "Master IP: $MASTER_IP"
echo "Slave IPs: $(echo $SLAVE_IPS | tr '\n' ' ')"
echo ""

# テストファイルを master に作成
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
TEST_FILE="sync_test_${TIMESTAMP}.html"
TEST_CONTENT="<h1>lsyncd sync test: $TIMESTAMP</h1>"

echo "[1/4] master にテストファイルを作成..."
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@"$MASTER_IP" \
  "echo '$TEST_CONTENT' | sudo tee /var/www/html/$TEST_FILE"

echo "[2/4] ${DELAY}秒待機（lsyncd 同期遅延）..."
sleep "$DELAY"

echo "[3/4] slave への同期を確認..."
FAILED=0
for SLAVE_IP in $SLAVE_IPS; do
  RESPONSE=$(curl -s --max-time 5 "http://$SLAVE_IP/$TEST_FILE" || echo "FAILED")
  if echo "$RESPONSE" | grep -q "$TIMESTAMP"; then
    echo "  ✅ slave $SLAVE_IP: 同期成功"
  else
    echo "  ❌ slave $SLAVE_IP: 同期失敗（レスポンス: $RESPONSE）"
    FAILED=1
  fi
done

echo "[4/4] テストファイルをクリーンアップ..."
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@"$MASTER_IP" \
  "sudo rm -f /var/www/html/$TEST_FILE"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "=============================="
  echo "✅ 全 slave への同期が確認できました"
  echo "=============================="
else
  echo "=============================="
  echo "❌ 一部の slave で同期が確認できませんでした"
  echo "   トラブルシューティング: docs/runbook/operations.md を参照"
  echo "=============================="
  exit 1
fi
