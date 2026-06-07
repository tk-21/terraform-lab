# ✅Phase 4 — Secrets Manager ローテーション + Chatwork 通知

## 前フェーズ確認

```bash
aws rds describe-db-proxies \
  --db-proxy-name arpl-rds-proxy \
  --query 'DBProxies[0].Status' --output text
# "available" であること
```

## このフェーズのゴール

- アプリ用 DB ユーザーのシークレットを Secrets Manager で管理
- 7日ごとの自動ローテーションを設定し、ローテーション中も接続断が発生しないことを確認
- ローテーション完了イベントを EventBridge → Lambda → Chatwork に通知

---

## Step 4-1: DB ユーザー作成スクリプト

```bash
# scripts/setup-db-user.sh
#!/bin/bash
# Aurora に管理者で接続してアプリ用ユーザーを作成する
# 実行: bash scripts/setup-db-user.sh
set -euo pipefail

PROXY_ENDPOINT=$(aws ssm get-parameter --name /arpl/rds-proxy/endpoint --query Parameter.Value --output text)
DB_NAME=$(aws ssm get-parameter --name /arpl/rds/db-name --query Parameter.Value --output text)
MASTER_SECRET=$(aws rds describe-db-clusters \
  --db-cluster-identifier arpl-aurora-cluster \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)
MASTER_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "$MASTER_SECRET" \
  --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# psql で接続してアプリ用ユーザーを作成
PGPASSWORD="$MASTER_PASS" psql \
  -h "$PROXY_ENDPOINT" \
  -U dbadmin \
  -d "$DB_NAME" \
  --set=sslmode=require <<'SQL'
-- アプリ用ユーザー作成（初期パスワードは後で Secrets Manager が管理）
CREATE USER appuser WITH PASSWORD 'TempPassword123!' LOGIN;
GRANT CONNECT ON DATABASE appdb TO appuser;
GRANT USAGE ON SCHEMA public TO appuser;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO appuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO appuser;

-- サンプルテーブル作成
CREATE TABLE IF NOT EXISTS items (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO items (name) VALUES ('test-item-1'), ('test-item-2');

\q
SQL

echo "DB user 'appuser' created successfully"
```

---

## Step 4-2: Secrets モジュール

### `terraform/modules/rotation/variables.tf`

```hcl
variable "prefix"          {}
variable "aws_region"      { default = "ap-northeast-1" }
variable "aws_account_id"  {}
variable "proxy_arn"       {}
variable "cluster_id"      {}
variable "chatwork_room_id" {}
variable "vpc_id"          {}
variable "private_app_subnet_ids" { type = list(string) }
variable "vpc_endpoint_sg_id"     {}
```

### `terraform/modules/rotation/main.tf`

```hcl
# =============================================================
# Secrets Manager 自動ローテーション設計:
# 1. アプリ用 DB ユーザー (appuser) のシークレットを管理
# 2. ローテーション Lambda が Proxy 経由で new/current/previous の 3段階で更新
# 3. Proxy はローテーション中も both old/new を一時的に受け付けるため接続断なし
# =============================================================

# ─── アプリ用 DB ユーザーシークレット ─────────────────────────
resource "aws_secretsmanager_secret" "app_db" {
  name        = "arpl/db/appuser"
  description = "Aurora appuserの認証情報（RDS Proxy IAM認証と組み合わせ）"

  # シークレット削除時の保持期間（0 = 即時削除、dev 用）
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_db_initial" {
  secret_id = aws_secretsmanager_secret.app_db.id

  # 初期値（ローテーション Lambda が最初のローテーション時に自動更新）
  secret_string = jsonencode({
    engine   = "postgres"
    host     = "PLACEHOLDER"  # Proxy エンドポイントは SSM から取得
    username = "appuser"
    password = "TempPassword123!"  # 初回ローテーションで変更される
    dbname   = "appdb"
    port     = 5432
  })

  lifecycle {
    # ローテーション後はTerraformが差分を検出しても無視
    ignore_changes = [secret_string]
  }
}

# ─── ローテーション Lambda ────────────────────────────────────
# Lambda 用セキュリティグループ（VPC Endpoint経由でSecretsManagerに接続）
resource "aws_security_group" "rotator" {
  name   = "${var.prefix}-rotator-sg"
  vpc_id = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "VPC Endpoint（SecretsManager）への接続"
  }

  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "RDS Proxy への接続（ローテーション検証用）"
  }
}

# Lambda IAM Role
resource "aws_iam_role" "rotator" {
  name = "${var.prefix}-rotator-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rotator" {
  name = "${var.prefix}-rotator-policy"
  role = aws_iam_role.rotator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRotation"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage"
        ]
        Resource = [aws_secretsmanager_secret.app_db.arn]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.prefix}-secret-rotator:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rotator_vpc" {
  role       = aws_iam_role.rotator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Lambda 関数（ローテーター）
data "archive_file" "rotator" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/rotator"
  output_path = "${path.root}/rotator.zip"
}

resource "aws_lambda_function" "rotator" {
  function_name    = "${var.prefix}-secret-rotator"
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.rotator.arn
  filename         = data.archive_file.rotator.output_path
  source_code_hash = data.archive_file.rotator.output_base64sha256
  architectures    = ["arm64"] # Graviton2

  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      PROXY_ENDPOINT_PARAM = "/arpl/rds-proxy/endpoint"
      DB_NAME_PARAM        = "/arpl/rds/db-name"
      POWERTOOLS_SERVICE_NAME = "${var.prefix}-rotator"
      LOG_LEVEL               = "INFO"
    }
  }

  vpc_config {
    subnet_ids         = var.private_app_subnet_ids
    security_group_ids = [aws_security_group.rotator.id]
  }
}

# Secrets Manager がローテーション Lambda を呼び出せる権限
resource "aws_lambda_permission" "secretsmanager" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotator.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.app_db.arn
}

# ─── ローテーション設定 ────────────────────────────────────────
resource "aws_secretsmanager_secret_rotation" "app_db" {
  secret_id           = aws_secretsmanager_secret.app_db.id
  rotation_lambda_arn = aws_lambda_function.rotator.arn

  rotation_rules {
    # 7日ごとにローテーション（CRON 形式）
    schedule_expression = "rate(7 days)"
  }

  # 設定と同時に即時ローテーションを実行する（初期パスワード変更）
  rotate_immediately = true
}

# ─── EventBridge + Chatwork 通知 ──────────────────────────────
# ローテーション完了イベントを Chatwork に通知する

resource "aws_ssm_parameter" "chatwork_token" {
  name  = "/arpl/chatwork/token"
  type  = "SecureString"
  value = "REPLACE_WITH_ACTUAL_TOKEN" # 初期値: 手動で更新する

  lifecycle {
    ignore_changes = [value] # Terraform で上書きしない
  }
}

resource "aws_ssm_parameter" "chatwork_room_id" {
  name  = "/arpl/chatwork/room-id"
  type  = "String"
  value = var.chatwork_room_id
}

# 通知 Lambda IAM Role
resource "aws_iam_role" "notifier" {
  name = "${var.prefix}-notifier-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "notifier" {
  name = "${var.prefix}-notifier-policy"
  role = aws_iam_role.notifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetSSMParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/arpl/chatwork/*"
        ]
      },
      {
        Sid    = "DecryptSSM"
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.prefix}-notifier:*"
      }
    ]
  })
}

data "archive_file" "notifier" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/notifier"
  output_path = "${path.root}/notifier.zip"
}

resource "aws_lambda_function" "notifier" {
  function_name    = "${var.prefix}-notifier"
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.notifier.arn
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256
  architectures    = ["arm64"]

  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      CHATWORK_TOKEN_PARAM   = "/arpl/chatwork/token"
      CHATWORK_ROOM_ID_PARAM = "/arpl/chatwork/room-id"
      POWERTOOLS_SERVICE_NAME = "${var.prefix}-notifier"
      LOG_LEVEL              = "INFO"
    }
  }
}

# EventBridge: Secrets Manager のローテーション完了イベントを検知
resource "aws_cloudwatch_event_rule" "rotation_complete" {
  name        = "${var.prefix}-rotation-complete"
  description = "Secrets Managerローテーション完了をChatworkに通知"

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["secretsmanager.amazonaws.com"]
      eventName   = ["RotateSecret"]
      requestParameters = {
        secretId = [aws_secretsmanager_secret.app_db.arn]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "notifier" {
  rule      = aws_cloudwatch_event_rule.rotation_complete.name
  target_id = "NotifierLambda"
  arn       = aws_lambda_function.notifier.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotation_complete.arn
}

output "app_secret_arn" { value = aws_secretsmanager_secret.app_db.arn }
```

---

## Step 4-3: Lambda コード

### `lambda/rotator/handler.py`

```python
"""
Secrets Manager カスタムローテーション Lambda
4ステップローテーション: createSecret → setSecret → testSecret → finishSecret

RDS Proxy + Aurora PostgreSQL 向けの実装。
Proxy が old/new 両方のパスワードを一時的に受け入れるため接続断なし。
"""
import boto3
import json
import logging
import os
import string
import secrets
import psycopg

from aws_lambda_powertools import Logger

logger = Logger()

sm_client = boto3.client("secretsmanager")
ssm_client = boto3.client("ssm")


def lambda_handler(event: dict, context) -> None:
    """
    Secrets Manager から呼び出されるローテーションハンドラー
    Step: createSecret | setSecret | testSecret | finishSecret
    """
    secret_arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]

    logger.info("ローテーション開始", extra={"step": step, "secret_arn": secret_arn})

    # シークレットの現在のステージ確認
    metadata = sm_client.describe_secret(SecretId=secret_arn)
    if not metadata.get("RotationEnabled"):
        raise ValueError(f"ローテーションが無効化されています: {secret_arn}")

    versions = metadata.get("VersionIdsToStages", {})
    if token not in versions:
        raise ValueError(f"トークンが見つかりません: {token}")

    if "AWSCURRENT" in versions[token]:
        logger.info("既に AWSCURRENT — ローテーション不要")
        return
    elif "AWSPENDING" not in versions[token]:
        raise ValueError(f"トークンが AWSPENDING にありません: {token}")

    dispatch = {
        "createSecret": create_secret,
        "setSecret":    set_secret,
        "testSecret":   test_secret,
        "finishSecret": finish_secret,
    }
    dispatch[step](sm_client, ssm_client, secret_arn, token)


def _generate_password(length: int = 32) -> str:
    """記号を含む安全なランダムパスワード生成"""
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def create_secret(sm, ssm, arn: str, token: str) -> None:
    """新しいパスワードを AWSPENDING ステージに保存"""
    try:
        sm.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)
        logger.info("AWSPENDING は既に存在 — スキップ")
        return
    except sm.exceptions.ResourceNotFoundException:
        pass

    current = json.loads(
        sm.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"]
    )
    current["password"] = _generate_password()

    sm.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=json.dumps(current),
        VersionStages=["AWSPENDING"],
    )
    logger.info("新しいパスワードを AWSPENDING に保存")


def set_secret(sm, ssm, arn: str, token: str) -> None:
    """DB ユーザーのパスワードを実際に変更する"""
    pending = json.loads(
        sm.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)["SecretString"]
    )
    current = json.loads(
        sm.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"]
    )

    proxy_endpoint = ssm.get_parameter(Name=os.environ["PROXY_ENDPOINT_PARAM"])["Parameter"]["Value"]
    db_name = ssm.get_parameter(Name=os.environ["DB_NAME_PARAM"])["Parameter"]["Value"]

    # 管理者権限で接続してパスワード変更
    # Proxy 経由で接続（require_tls=true のため sslmode=require）
    conn_str = (
        f"host={proxy_endpoint} port=5432 dbname={db_name} "
        f"user={current['username']} password={current['password']} sslmode=require"
    )
    with psycopg.connect(conn_str) as conn:
        conn.autocommit = True
        with conn.cursor() as cur:
            # ALTER USER でパスワード変更（DROP/CREATE は避ける）
            cur.execute(
                "ALTER USER %s WITH PASSWORD %s",
                (pending["username"], pending["password"])
            )
    logger.info("DBパスワード変更完了", extra={"username": pending["username"]})


def test_secret(sm, ssm, arn: str, token: str) -> None:
    """新しいパスワードで接続テスト"""
    pending = json.loads(
        sm.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)["SecretString"]
    )
    proxy_endpoint = ssm.get_parameter(Name=os.environ["PROXY_ENDPOINT_PARAM"])["Parameter"]["Value"]
    db_name = ssm.get_parameter(Name=os.environ["DB_NAME_PARAM"])["Parameter"]["Value"]

    conn_str = (
        f"host={proxy_endpoint} port=5432 dbname={db_name} "
        f"user={pending['username']} password={pending['password']} sslmode=require"
    )
    with psycopg.connect(conn_str) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
    logger.info("新パスワードでの接続テスト成功")


def finish_secret(sm, ssm, arn: str, token: str) -> None:
    """AWSPENDING を AWSCURRENT に昇格"""
    metadata = sm.describe_secret(SecretId=arn)
    current_version = next(
        v for v, stages in metadata["VersionIdsToStages"].items()
        if "AWSCURRENT" in stages
    )

    if current_version == token:
        logger.info("既に AWSCURRENT — 完了")
        return

    sm.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )
    logger.info("ローテーション完了: AWSCURRENT 更新")
```

### `lambda/rotator/requirements.txt`

```
aws-lambda-powertools==2.36.1
psycopg[binary]==3.1.18
boto3==1.34.0
```

### `lambda/notifier/handler.py`

```python
"""
Secrets Manager ローテーション完了を Chatwork に通知する Lambda
EventBridge から呼び出される
"""
import boto3
import json
import os
import urllib.request
import urllib.parse

from aws_lambda_powertools import Logger

logger = Logger()
ssm = boto3.client("ssm")


def lambda_handler(event: dict, context) -> None:
    """EventBridge イベントを受信して Chatwork に通知"""
    logger.info("ローテーション完了通知", extra={"event": event})

    # SSM からトークンとルームIDを取得
    token_param = ssm.get_parameter(
        Name=os.environ["CHATWORK_TOKEN_PARAM"],
        WithDecryption=True,
    )
    room_id_param = ssm.get_parameter(Name=os.environ["CHATWORK_ROOM_ID_PARAM"])

    token = token_param["Parameter"]["Value"]
    room_id = room_id_param["Parameter"]["Value"]

    # イベント詳細からシークレット名を取得
    secret_id = event.get("detail", {}).get("requestParameters", {}).get("secretId", "不明")
    event_time = event.get("time", "不明")

    message = (
        f"[info][title]🔐 Secrets Manager ローテーション完了[/title]"
        f"シークレット: {secret_id}\n"
        f"完了時刻: {event_time}\n"
        f"プロジェクト: aurora-rds-proxy-lab[/info]"
    )

    # Chatwork API 呼び出し
    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({"body": message}).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork通知成功", extra={"status": resp.status})
```

---

## Step 4-4: environments/dev/main.tf に追記

```hcl
module "rotation" {
  source = "../../modules/rotation"

  prefix                  = var.prefix
  aws_region              = var.aws_region
  aws_account_id          = data.aws_caller_identity.current.account_id
  proxy_arn               = module.rds_proxy.proxy_arn
  cluster_id              = module.aurora.cluster_id
  chatwork_room_id        = var.chatwork_room_id
  vpc_id                  = module.networking.vpc_id
  private_app_subnet_ids  = module.networking.private_app_subnet_ids
  vpc_endpoint_sg_id      = module.networking.vpc_endpoint_sg_id
}
```

---

## Step 4-5: 実行・検証

```bash
# Chatwork トークンを SSM に登録（手動）
aws ssm put-parameter \
  --name /arpl/chatwork/token \
  --value "YOUR_CHATWORK_API_TOKEN" \
  --type SecureString \
  --overwrite

cd terraform/environments/dev
terraform fmt -recursive
terraform validate
terraform apply

# DB ユーザー作成スクリプトを実行
bash scripts/setup-db-user.sh

# 即時ローテーションをトリガー（検証用）
aws secretsmanager rotate-secret \
  --secret-id arpl/db/appuser \
  --rotate-immediately

# ローテーション状態確認
aws secretsmanager describe-secret \
  --secret-id arpl/db/appuser \
  --query '{Status:RotationEnabled,LastRotated:LastRotatedDate,NextRotation:NextRotationDate}' \
  --output json
```

### ローテーション検証スクリプト

```bash
# scripts/verify-rotation.sh
#!/bin/bash
# ローテーション中の接続断有無を確認する
set -euo pipefail

PROXY_ENDPOINT=$(aws ssm get-parameter --name /arpl/rds-proxy/endpoint --query Parameter.Value --output text)

echo "=== ローテーション前の接続確認 ==="
SECRET=$(aws secretsmanager get-secret-value --secret-id arpl/db/appuser --query SecretString --output text)
PASSWORD=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# 10秒ごとに接続確認（ローテーション中も成功し続けることを確認）
for i in {1..20}; do
  RESULT=$(PGPASSWORD="$PASSWORD" psql -h "$PROXY_ENDPOINT" -U appuser -d appdb \
    -c "SELECT NOW()::TEXT" -t 2>&1 || echo "ERROR")
  echo "[$i] $(date '+%H:%M:%S') - $RESULT"
  sleep 10
done
```

---

## フェーズ完了チェック

- [ ] `arpl/db/appuser` シークレットが Secrets Manager に存在
- [ ] ローテーション Lambda が `available`
- [ ] `rotate-immediately` でローテーションが成功（Lambda ログ確認）
- [ ] Chatwork に通知が届いている
- [ ] ローテーション中に接続断が発生しないことを `verify-rotation.sh` で確認
- [ ] ADR 003 を自分の言葉で記述

## 口頭説明チェック（Phase 4）

以下を5分で説明できること:

1. ローテーション 4 ステップ（createSecret / setSecret / testSecret / finishSecret）の順序と各処理内容
2. なぜ RDS Proxy があるとローテーション中も接続断が起きないのか
3. `rotate_immediately = true` の意味とリスク