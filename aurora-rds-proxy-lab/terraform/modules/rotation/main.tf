# =============================================================
# Secrets Manager 自動ローテーション設計:
# 1. appuser の認証情報を Secrets Manager で管理
# 2. ローテーション Lambda は Aurora に直接接続（Proxy は iam_auth=REQUIRED のため不可）
# 3. Proxy はセッションをキャッシュするため、ローテーション中も接続断なし
# 4. ローテーション完了イベントを EventBridge → Notifier Lambda → Chatwork に通知
# =============================================================

# ─── appuser シークレット ─────────────────────────────────────
resource "aws_secretsmanager_secret" "app_db" {
  name        = "arpl/db/appuser"
  description = "Aurora appuser の認証情報（ローテーション Lambda が自動管理）"

  # dev 環境: 即時削除（本番では 7 以上に設定）
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_db_initial" {
  secret_id = aws_secretsmanager_secret.app_db.id

  # 初期値: 最初のローテーション時にパスワードが自動更新される
  secret_string = jsonencode({
    engine   = "postgres"
    host     = var.cluster_endpoint
    username = "appuser"
    password = "TempPassword123!"
    dbname   = "appdb"
    port     = 5432
  })

  lifecycle {
    # ローテーション後に Terraform が差分検出しても上書きしない
    ignore_changes = [secret_string]
  }
}

# ─── SSM Parameter Store ──────────────────────────────────────
# ローテーション Lambda が Aurora に直接接続するためのエンドポイントを保存
resource "aws_ssm_parameter" "aurora_endpoint" {
  name  = "/arpl/aurora/endpoint"
  type  = "String"
  value = var.cluster_endpoint
}

# ─── ローテーション Lambda SG ─────────────────────────────────
resource "aws_security_group" "rotator" {
  name        = "${var.prefix}-rotator-sg"
  description = "シークレットローテーション Lambda 用 SG"
  vpc_id      = var.vpc_id

  # Aurora Writer への直接接続（Proxy は iam_auth=REQUIRED のためバイパス）
  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Aurora Writer への直接接続（パスワード変更用）"
  }

  # SecretsManager / SSM の VPC Endpoint への接続
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "VPC Endpoint（SecretsManager / SSM）への接続"
  }
}

# Aurora SG にローテーション Lambda からのイングレスを追加
resource "aws_security_group_rule" "aurora_allow_rotator" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.aurora_sg_id
  source_security_group_id = aws_security_group.rotator.id
  description              = "ローテーション Lambda からの直接接続を許可"
}

# ─── ローテーション Lambda IAM ────────────────────────────────
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
        Sid    = "RotateAppSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
        ]
        Resource = [aws_secretsmanager_secret.app_db.arn]
      },
      {
        # マスターユーザーで Aurora に直接接続してパスワード変更
        Sid      = "GetMasterSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.master_secret_arn]
      },
      {
        Sid    = "GetSSMParams"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/arpl/aurora/endpoint",
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/arpl/rds/db-name",
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.prefix}-secret-rotator:*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rotator_vpc" {
  role       = aws_iam_role.rotator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ─── ローテーション Lambda ────────────────────────────────────
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
  architectures    = ["arm64"]
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      # マスターユーザーで Aurora に直接接続してパスワード変更
      MASTER_SECRET_ARN       = var.master_secret_arn
      AURORA_ENDPOINT_PARAM   = "/arpl/aurora/endpoint"
      DB_NAME_PARAM           = "/arpl/rds/db-name"
      POWERTOOLS_SERVICE_NAME = "${var.prefix}-rotator"
      LOG_LEVEL               = "INFO"
    }
  }

  vpc_config {
    subnet_ids         = var.private_app_subnet_ids
    security_group_ids = [aws_security_group.rotator.id]
  }

  depends_on = [aws_iam_role_policy_attachment.rotator_vpc]
}

# Secrets Manager がローテーション Lambda を呼び出す権限
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
    schedule_expression = "rate(7 days)"
  }

  # Terraform apply と同時に初回ローテーションを実行（初期パスワードを即時変更）
  rotate_immediately = true

  depends_on = [aws_lambda_permission.secretsmanager]
}

# ─── Chatwork 通知: SSM パラメータ ───────────────────────────
resource "aws_ssm_parameter" "chatwork_token" {
  name  = "/arpl/chatwork/token"
  type  = "SecureString"
  value = "REPLACE_WITH_ACTUAL_TOKEN"

  lifecycle {
    # terraform apply で上書きしない（手動で aws ssm put-parameter --overwrite を使う）
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "chatwork_room_id" {
  name  = "/arpl/chatwork/room-id"
  type  = "String"
  value = var.chatwork_room_id
}

# ─── 通知 Lambda IAM ─────────────────────────────────────────
# Notifier は VPC 外で動作（Chatwork API はインターネット接続が必要、NAT Gateway 禁止のため）
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
        Sid    = "GetSSMParams"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/arpl/chatwork/token",
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/arpl/chatwork/room-id",
        ]
      },
      {
        # SSM SecureString (KMS 暗号化) の復号
        Sid      = "DecryptSSMSecureString"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
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
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.prefix}-notifier:*"
      },
    ]
  })
}

# ─── 通知 Lambda ─────────────────────────────────────────────
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
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      CHATWORK_TOKEN_PARAM    = "/arpl/chatwork/token"
      CHATWORK_ROOM_ID_PARAM  = "/arpl/chatwork/room-id"
      POWERTOOLS_SERVICE_NAME = "${var.prefix}-notifier"
      LOG_LEVEL               = "INFO"
    }
  }
  # VPC なし: Chatwork API（インターネット）への直接接続のため
}

# ─── EventBridge: ローテーション完了通知 ─────────────────────
# CloudTrail 経由で RotateSecret API コール完了を検知する
resource "aws_cloudwatch_event_rule" "rotation_complete" {
  name        = "${var.prefix}-rotation-complete"
  description = "Secrets Manager ローテーション完了を Chatwork に通知"

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
