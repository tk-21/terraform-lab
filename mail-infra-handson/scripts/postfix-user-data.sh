#!/bin/bash
# EC2起動時に自動実行されるユーザーデータスクリプト
# Postfix + メール関連ツールをインストールして設定する
# Terraformのtemplatefile()でドメイン名が展開される

set -euo pipefail

DOMAIN="${domain_name}"
MAIL_HOSTNAME="mail.$${DOMAIN}"

# ─────────────────────────────────────────────
# 1. パッケージ更新・インストール
# ─────────────────────────────────────────────
dnf update -y
dnf install -y postfix mailx telnet bind-utils cyrus-sasl-plain

# ─────────────────────────────────────────────
# 2. Postfix基本設定
# ─────────────────────────────────────────────
# main.cfを上書きして設定を適用する
# postconfコマンドで設定値を個別に書き込む（既存設定を安全に上書きできる）

postconf -e "myhostname = $${MAIL_HOSTNAME}"
postconf -e "mydomain = $${DOMAIN}"
postconf -e "myorigin = \$mydomain"

# inet_interfaces = all: 全NICでリッスン（デフォルトはloopbackのみ）
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"

# mydestination: このサーバーが最終配送先となるドメイン
# $myhostname宛のメールはローカル配送し、他はリレーホストへ転送する
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"

# ─────────────────────────────────────────────
# 3. SESスマートホスト設定
# ─────────────────────────────────────────────
# relayhost: 全アウトバウンドメールをSESのSMTPエンドポイントへ転送する
# []で囲むことでMXルックアップをスキップしてAレコードを直接引く
postconf -e "relayhost = [email-smtp.ap-northeast-1.amazonaws.com]:587"

# SASL認証: SESへの接続時にユーザー名・パスワードで認証する
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
postconf -e "smtp_sasl_security_options = noanonymous"

# TLS設定: SESはSTARTTLSを要求するため、暗号化レベルをencryptに設定
postconf -e "smtp_use_tls = yes"
postconf -e "smtp_tls_security_level = encrypt"
postconf -e "smtp_tls_note_starttls_offer = yes"

# ─────────────────────────────────────────────
# 4. SASL認証情報のプレースホルダー作成
# ─────────────────────────────────────────────
# 実際のSMTPクレデンシャルはPhase 3でSES設定後に入力する
# Phase 3完了後に以下を実行:
#   sudo vi /etc/postfix/sasl_passwd
#   [email-smtp.ap-northeast-1.amazonaws.com]:587 <USERNAME>:<PASSWORD>
#   sudo postmap /etc/postfix/sasl_passwd
#   sudo chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
#   sudo systemctl reload postfix
cat > /etc/postfix/sasl_passwd << 'SASL_EOF'
# SES SMTPクレデンシャルをPhase 3で設定する
# 形式: [endpoint]:port USERNAME:PASSWORD
# [email-smtp.ap-northeast-1.amazonaws.com]:587 AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI...
SASL_EOF

chmod 600 /etc/postfix/sasl_passwd

# ─────────────────────────────────────────────
# 5. Postfix起動・自動起動設定
# ─────────────────────────────────────────────
systemctl enable postfix
systemctl start postfix

# ─────────────────────────────────────────────
# 6. ユーティリティエイリアス設定
# ─────────────────────────────────────────────
cat >> /etc/bashrc << 'BASHRC_EOF'
# メール関連ユーティリティエイリアス
alias maillog='tail -f /var/log/maillog'
alias mq='mailq'
alias postdebug='sudo postqueue -p && echo "---" && sudo postconf -n'
BASHRC_EOF

# 起動完了をログに記録
echo "$(date): Phase2 user_data.sh 完了 - Postfix installed on $${MAIL_HOSTNAME}" >> /var/log/user-data.log
