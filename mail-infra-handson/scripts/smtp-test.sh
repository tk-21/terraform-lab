#!/bin/bash
# SMTPプロトコルを手打ちでテストするための学習用スクリプト
# 使用方法: ./scripts/smtp-test.sh <EC2_IP> <SENDER> <RECIPIENT>
#
# このスクリプトはSMTPの会話を「見える化」するための学習ツール
# 実際の接続は手動でtelnetを実行してSMTPコマンドを体験すること

set -euo pipefail

EC2_IP="${1:-}"
SENDER="${2:-}"
RECIPIENT="${3:-}"

# ─────────────────────────────────────────────
# 引数チェック
# ─────────────────────────────────────────────
if [[ -z "$EC2_IP" || -z "$SENDER" || -z "$RECIPIENT" ]]; then
  echo "使用方法: $0 <EC2_IP> <SENDER> <RECIPIENT>"
  echo "例: $0 203.0.113.1 sender@example.com recipient@example.com"
  exit 1
fi

echo "============================================"
echo "  SMTPプロトコル学習ガイド"
echo "============================================"
echo ""

# ─────────────────────────────────────────────
# 1. 接続確認
# ─────────────────────────────────────────────
echo "[1] SMTP接続確認 (port 25)"
echo "--------------------------------------------"
if nc -z -w 5 "$EC2_IP" 25 2>/dev/null; then
  echo "✓ port 25 が開いています"
else
  echo "✗ port 25 に接続できません"
  echo "  → Security Groupのインバウンドルールを確認してください"
  echo "  → my_ip の設定が正しいか確認してください"
fi
echo ""

# ─────────────────────────────────────────────
# 2. SMTPコマンド実行順序の解説
# ─────────────────────────────────────────────
echo "[2] SMTPコマンドの実行順序（手打ち手順）"
echo "--------------------------------------------"
echo "以下のコマンドを順番に手打ちすることでメール送信の仕組みを体験できます:"
echo ""
echo "  $ telnet $EC2_IP 25"
echo ""
echo "  接続後、以下のコマンドを順番に入力してください:"
echo ""
echo "  EHLO mytest.example.com"
echo "    → サーバーに自分のドメインを名乗る（拡張SMTPの挨拶）"
echo "    → サーバーがサポートするコマンド一覧が返ってくる"
echo ""
echo "  MAIL FROM:<$SENDER>"
echo "    → 送信者のアドレスを指定（エンベロープFrom）"
echo "    → メールヘッダーのFromとは別物（重要！）"
echo ""
echo "  RCPT TO:<$RECIPIENT>"
echo "    → 受信者のアドレスを指定（エンベロープTo）"
echo "    → 複数の受信者がいる場合はこのコマンドを繰り返す"
echo ""
echo "  DATA"
echo "    → メール本文の入力開始を宣言"
echo "    → サーバーが '354 End data with <CR><LF>.<CR><LF>' と返す"
echo ""
echo "  Subject: テストメール"
echo "  From: $SENDER"
echo "  To: $RECIPIENT"
echo "  "
echo "  これはSMTPプロトコルの手動テストです。"
echo "  Postfixのキューに入り、SES経由で送信されます。"
echo "  ."
echo "    → 本文終了。ピリオド1文字だけの行が終端マーカー"
echo ""
echo "  QUIT"
echo "    → セッション終了"
echo ""

# ─────────────────────────────────────────────
# 3. ローカル接続テスト（EC2内部から）
# ─────────────────────────────────────────────
echo "[3] EC2内部からのローカルテスト方法"
echo "--------------------------------------------"
echo "SSMセッション内で実行してください:"
echo ""
echo "  # localhostへのtelnet接続"
echo "  telnet localhost 25"
echo ""
echo "  # または mailx コマンドで直接送信"
echo "  echo 'テストメール本文' | mailx -s 'テスト' -r $SENDER $RECIPIENT"
echo ""

# ─────────────────────────────────────────────
# 4. メールキュー確認コマンド
# ─────────────────────────────────────────────
echo "[4] メールキュー確認コマンド（EC2内で実行）"
echo "--------------------------------------------"
echo "  mailq                    # キュー内のメール一覧"
echo "  postqueue -p             # 詳細版キュー表示"
echo "  postcat -q <QUEUE_ID>    # 特定メールの中身を確認"
echo "  postqueue -f             # deferredキューを即時再送"
echo "  postsuper -d ALL         # キューを全削除（テスト時のみ）"
echo ""

# ─────────────────────────────────────────────
# 5. ログリアルタイム確認
# ─────────────────────────────────────────────
echo "[5] Postfixログのリアルタイム確認（EC2内で実行）"
echo "--------------------------------------------"
echo "  tail -f /var/log/maillog"
echo "  # または定義済みエイリアス:"
echo "  maillog"
echo ""
echo "============================================"
echo "  ⚠️  注意: Phase 3（SES設定）完了後に"
echo "  実際のメール送信が可能になります"
echo "============================================"
