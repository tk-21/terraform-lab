#!/bin/bash
set -euo pipefail

CF_DOMAIN="${1:?Usage: $0 <cloudfront-domain> [alb-dns]}"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_status="$2"
  local url="$3"
  local extra_args="${4:-}"

  actual=$(curl -s -o /dev/null -w "%{http_code}" ${extra_args} "${url}")

  if [ "${actual}" = "${expected_status}" ]; then
    echo "✅ PASS: ${name} (HTTP ${actual})"
    PASS=$((PASS + 1))
  else
    echo "❌ FAIL: ${name} (expected ${expected_status}, got ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== WAF 動作検証 ==="
echo "対象: https://${CF_DOMAIN}"
echo ""

# 正常リクエスト（許可）
check "正常リクエスト" "200" "https://${CF_DOMAIN}/"

# SQLi → WAF AWSManagedRulesSQLiRuleSet でブロック
check "SQLi ブロック" "403" "https://${CF_DOMAIN}/?id=1' OR '1'='1"

# カスタムルール: 管理パス → ブロック
check "管理パス /admin" "403" "https://${CF_DOMAIN}/admin"
check "管理パス /.env"  "403" "https://${CF_DOMAIN}/.env"
check "管理パス /.git"  "403" "https://${CF_DOMAIN}/.git/config"

# カスタムルール: 不正 UA → ブロック
check "不正 UA: sqlmap" "403" "https://${CF_DOMAIN}/" "-A 'sqlmap/1.0'"
check "不正 UA: nikto"  "403" "https://${CF_DOMAIN}/" "-A 'nikto'"
check "不正 UA: masscan" "403" "https://${CF_DOMAIN}/" "-A 'masscan'"

# XSS → WAF AWSManagedRulesKnownBadInputsRuleSet でブロック
check "XSS ブロック" "403" "https://${CF_DOMAIN}/?q=<script>alert(1)</script>"

# ALB 直接アクセス → X-CloudFront-Secret ヘッダーなしで Lambda@Edge が弾く
ALB_DNS="${2:-}"
if [ -n "${ALB_DNS}" ]; then
  check "ALB 直接アクセス（CF ヘッダーなし）" "403" "http://${ALB_DNS}/"
else
  echo "⚠️  SKIP: ALB 直接アクセスチェック（第2引数 ALB_DNS が未指定）"
fi

echo ""
echo "=== 結果: PASS=${PASS}, FAIL=${FAIL} ==="
[ "${FAIL}" -eq 0 ] && exit 0 || exit 1
