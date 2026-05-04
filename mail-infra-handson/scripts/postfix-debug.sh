#!/bin/bash
# Postfixデバッグスクリプト
# SSMセッション内（EC2上）で実行する
#
# 使用方法: sudo bash /tmp/postfix-debug.sh
# または: curl -s <このスクリプトのURL> | sudo bash

set -euo pipefail

echo "============================================"
echo "  Postfix状態診断レポート"
echo "  $(date)"
echo "============================================"
echo ""

# ─────────────────────────────────────────────
# 1. Postfixサービスステータス
# ─────────────────────────────────────────────
echo "[1] Postfixサービスステータス"
echo "--------------------------------------------"
systemctl status postfix --no-pager -l || true
echo ""

# ─────────────────────────────────────────────
# 2. メールキュー状況
# ─────────────────────────────────────────────
echo "[2] メールキュー状況"
echo "--------------------------------------------"
echo "--- mailq ---"
mailq || true
echo ""
echo "--- postqueue -p (詳細) ---"
postqueue -p 2>/dev/null || echo "(キューは空です)"
echo ""

# ─────────────────────────────────────────────
# 3. main.cfの設定確認（デフォルト値と異なる設定のみ表示）
# ─────────────────────────────────────────────
echo "[3] Postfix設定 (postconf -n)"
echo "--------------------------------------------"
postconf -n
echo ""

# ─────────────────────────────────────────────
# 4. 最新メールログ
# ─────────────────────────────────────────────
echo "[4] 最新メールログ 50行"
echo "--------------------------------------------"
if [[ -f /var/log/maillog ]]; then
  tail -50 /var/log/maillog
else
  echo "maillogが見つかりません。journalctlを確認します:"
  journalctl -u postfix --no-pager -n 50 || true
fi
echo ""

# ─────────────────────────────────────────────
# 5. Postfixプロセス一覧
# ─────────────────────────────────────────────
echo "[5] Postfixプロセス一覧"
echo "--------------------------------------------"
ps aux | grep -E "(postfix|master|qmgr|smtpd|smtp)" | grep -v grep || echo "(Postfixプロセスが見つかりません)"
echo ""

# ─────────────────────────────────────────────
# 6. ポートのリスン確認
# ─────────────────────────────────────────────
echo "[6] SMTPポートのリスン確認"
echo "--------------------------------------------"
echo "--- port 25, 587 ---"
ss -tlnp | grep -E ":(25|587)\s" || echo "(SMTPポートがリスンしていません)"
echo ""
echo "--- 全リスンポート ---"
ss -tlnp
echo ""

# ─────────────────────────────────────────────
# 7. SASL認証設定確認
# ─────────────────────────────────────────────
echo "[7] SASL認証設定"
echo "--------------------------------------------"
if [[ -f /etc/postfix/sasl_passwd ]]; then
  echo "sasl_passwd ファイルが存在します"
  echo "パーミッション: $(stat -c '%a' /etc/postfix/sasl_passwd)"
  if [[ -f /etc/postfix/sasl_passwd.db ]]; then
    echo "sasl_passwd.db (ハッシュ済み) が存在します"
  else
    echo "⚠️  sasl_passwd.db が存在しません"
    echo "   → sudo postmap /etc/postfix/sasl_passwd を実行してください"
  fi
else
  echo "⚠️  /etc/postfix/sasl_passwd が存在しません"
  echo "   → Phase 3でSES SMTPクレデンシャルを設定してください"
fi
echo ""

# ─────────────────────────────────────────────
# 8. DNS解決確認
# ─────────────────────────────────────────────
echo "[8] SES SMTPエンドポイントの名前解決確認"
echo "--------------------------------------------"
SES_ENDPOINT="email-smtp.ap-northeast-1.amazonaws.com"
echo "エンドポイント: $SES_ENDPOINT"
if host "$SES_ENDPOINT" > /dev/null 2>&1; then
  host "$SES_ENDPOINT"
  echo "✓ 名前解決成功"
else
  echo "✗ 名前解決失敗 → DNS設定を確認してください"
fi
echo ""

echo "============================================"
echo "  診断完了"
echo "============================================"
