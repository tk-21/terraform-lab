#!/bin/bash
set -euo pipefail

# stress-ng インストール（FIS 実験で CPU 負荷注入に使用）
dnf install -y stress-ng

# SSM Agent は Amazon Linux 2023 にプリインストール済み
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# ヘルスチェックエンドポイント用の簡易 HTTP サーバーをセットアップする
dnf install -y python3

mkdir -p /var/www/html

# IMDSv2 経由でインスタンス ID を取得する
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "{\"status\":\"ok\",\"instance\":\"$INSTANCE_ID\",\"prefix\":\"${prefix}\",\"env\":\"${env}\"}" \
  > /var/www/html/health

cat > /etc/systemd/system/healthcheck.service << 'UNIT'
[Unit]
Description=Simple health check HTTP server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server 80 --directory /var/www/html
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable healthcheck
systemctl start healthcheck
