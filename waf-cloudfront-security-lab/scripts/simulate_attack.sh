#!/bin/bash
set -euo pipefail

CF_DOMAIN="${1:?Usage: $0 <cloudfront-domain>}"

echo "攻撃シミュレーション開始（ログは S3 に記録されます）"
echo "対象: https://${CF_DOMAIN}"
echo ""

encode() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# SQLi 攻撃パターン
echo "--- SQLi パターン ---"
sqli_payloads=(
  "' OR '1'='1"
  "' OR 1=1--"
  "'; DROP TABLE users;--"
  "' UNION SELECT 1,2,3--"
  "1' AND SLEEP(5)--"
  "' OR 'x'='x"
  "admin'--"
  "' OR 1=1#"
  "1; SELECT * FROM information_schema.tables"
  "' AND 1=CONVERT(int, (SELECT TOP 1 name FROM sysobjects WHERE xtype='U'))--"
)

for payload in "${sqli_payloads[@]}"; do
  encoded=$(encode "${payload}")
  echo "  送信: ?id=${payload}"
  curl -s -o /dev/null "https://${CF_DOMAIN}/?id=${encoded}"
  sleep 0.5
done

# XSS 攻撃パターン
echo ""
echo "--- XSS パターン ---"
xss_payloads=(
  "<script>alert(1)</script>"
  "javascript:alert(document.cookie)"
  "<img src=x onerror=alert(1)>"
  "<svg onload=alert(1)>"
  "';alert(String.fromCharCode(88,83,83))//';alert(String.fromCharCode(88,83,83))//\";"
)

for payload in "${xss_payloads[@]}"; do
  encoded=$(encode "${payload}")
  echo "  送信: ?q=${payload}"
  curl -s -o /dev/null "https://${CF_DOMAIN}/?q=${encoded}"
  sleep 0.5
done

# スキャンツール UA
echo ""
echo "--- スキャンツール UA パターン ---"
for ua in "sqlmap/1.0" "nikto" "nessus" "masscan" "nmap scripting engine" "dirbuster" "acunetix"; do
  echo "  UA: ${ua}"
  curl -s -o /dev/null -A "${ua}" "https://${CF_DOMAIN}/"
  sleep 0.3
done

# 管理パス探索
echo ""
echo "--- 管理パス探索パターン ---"
admin_paths=("/admin" "/.env" "/.git/config" "/wp-admin" "/phpmyadmin" "/.aws/credentials" "/etc/passwd")
for path in "${admin_paths[@]}"; do
  echo "  パス: ${path}"
  curl -s -o /dev/null "https://${CF_DOMAIN}${path}"
  sleep 0.3
done

echo ""
echo "完了。5 分後に S3 でログを確認してください。"
echo ""
echo "Athena クエリ例:"
echo "  - athena/queries/top_blocked_ips.sql     : ブロック上位 IP"
echo "  - athena/queries/rule_match_summary.sql  : ルール別マッチ集計"
echo "  - athena/queries/country_breakdown.sql   : 国別アクセス分析"
