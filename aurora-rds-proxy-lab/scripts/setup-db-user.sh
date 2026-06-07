#!/bin/bash
# Aurora に管理者で接続してアプリ用ユーザーを作成する
# 実行: bash scripts/setup-db-user.sh
set -euo pipefail

PROXY_ENDPOINT=$(aws ssm get-parameter --name /arpl/rds-proxy/endpoint --query Parameter.Value --output text)
DB_NAME=$(aws ssm get-parameter --name /arpl/rds/db-name --query Parameter.Value --output text)

# Aurora マスターユーザーのシークレット ARN を取得
MASTER_SECRET=$(aws rds describe-db-clusters \
  --db-cluster-identifier arpl-aurora-cluster \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)

MASTER_USER=$(aws secretsmanager get-secret-value \
  --secret-id "$MASTER_SECRET" \
  --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")

MASTER_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "$MASTER_SECRET" \
  --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

echo "=== Aurora 接続先: $PROXY_ENDPOINT / DB: $DB_NAME ==="

PGPASSWORD="$MASTER_PASS" psql \
  -h "$PROXY_ENDPOINT" \
  -U "$MASTER_USER" \
  -d "$DB_NAME" \
  --set=sslmode=require <<'SQL'
-- アプリ用ユーザー作成
-- 初期パスワードは Secrets Manager のローテーションで自動変更される
CREATE USER appuser WITH PASSWORD 'TempPassword123!' LOGIN;
GRANT CONNECT ON DATABASE appdb TO appuser;
GRANT USAGE ON SCHEMA public TO appuser;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO appuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO appuser;

-- サンプルテーブル
CREATE TABLE IF NOT EXISTS items (
  id         SERIAL PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO items (name) VALUES ('test-item-1'), ('test-item-2');

\q
SQL

echo "DB ユーザー 'appuser' の作成が完了しました"
