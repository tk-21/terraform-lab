data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  tags       = merge(var.tags, { Module = "inbound-pipeline" })
}

# ============================================================
# S3 バケット（受信メール保存用）
# ============================================================

resource "random_id" "bucket_suffix" {
  # S3バケット名はグローバルで一意である必要があるためランダムサフィックスを付与
  byte_length = 4
}

resource "aws_s3_bucket" "inbound_mail" {
  bucket = "mail-handson-inbound-${random_id.bucket_suffix.hex}"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "inbound_mail" {
  bucket = aws_s3_bucket.inbound_mail.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "inbound_mail" {
  # SSE-S3（AES-256）: 追加コストなしでサーバー側暗号化を実現
  bucket = aws_s3_bucket.inbound_mail.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "inbound_mail" {
  bucket = aws_s3_bucket.inbound_mail.id
  rule {
    id     = "inbound-mail-lifecycle"
    status = "Enabled"
    transition {
      # 30日後にGlacierへ移行: アクセス頻度の低い過去メールのストレージコストを削減
      days          = 30
      storage_class = "GLACIER"
    }
    expiration { days = 90 }
  }
  depends_on = [aws_s3_bucket_versioning.inbound_mail]
}

resource "aws_s3_bucket_public_access_block" "inbound_mail" {
  # メール本文には個人情報・機密情報が含まれる可能性があるため全面ブロック
  bucket                  = aws_s3_bucket.inbound_mail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "inbound_mail" {
  # SESがS3にメールを書き込むために必要なバケットポリシー
  # aws:SourceAccount 条件でアカウント外からのなりすましアクセスを防止する
  bucket = aws_s3_bucket.inbound_mail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSESPutObject"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.inbound_mail.arn}/*"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.inbound_mail]
}

# ============================================================
# DynamoDB テーブル（スパムログ）
# ============================================================

resource "aws_dynamodb_table" "spam_log" {
  # スパム判定ログ: 各受信メールの判定結果を記録する
  # 判定ロジックのチューニングやインシデント調査で参照する
  name         = "mail-handson-spam-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "message_id"
  range_key    = "received_at"

  attribute {
    name = "message_id"
    type = "S"
  }

  attribute {
    name = "received_at"
    type = "S"
  }

  ttl {
    # 30日後に自動削除（スパムログは短期保持で十分）
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = local.tags
}

# ============================================================
# IAM Role（spam_handler Lambda用）
# ============================================================

resource "aws_iam_role" "spam_handler_lambda" {
  # IAMロール名は64文字以内（現在: 36文字）
  name = "mail-handson-spam-handler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "spam_handler_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.spam_handler_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/mail-handson-spam-handler:*"
    }]
  })
}

resource "aws_iam_role_policy" "spam_handler_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.spam_handler_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteSpamLog"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.spam_log.arn
      },
      {
        Sid      = "ReadSuppressionList"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = var.suppression_table_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "spam_handler_cloudwatch" {
  name = "cloudwatch-metrics"
  role = aws_iam_role.spam_handler_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["cloudwatch:PutMetricData"]
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = "MailInfraHandson" } }
    }]
  })
}

resource "aws_iam_role_policy" "spam_handler_xray" {
  name = "xray-tracing"
  role = aws_iam_role.spam_handler_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource = "*"
    }]
  })
}

# ============================================================
# Lambda Function（spam_handler）
# ============================================================

data "archive_file" "spam_handler" {
  type        = "zip"
  source_file = "${path.module}/lambda/spam_handler.py"
  output_path = "${path.module}/lambda/spam_handler.zip"
}

resource "aws_lambda_function" "spam_handler" {
  # SES Receipt RuleのLambdaアクションとして受信メールを解析するハンドラー
  function_name    = "mail-handson-spam-handler"
  role             = aws_iam_role.spam_handler_lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "spam_handler.lambda_handler"
  filename         = data.archive_file.spam_handler.output_path
  source_code_hash = data.archive_file.spam_handler.output_base64sha256
  timeout          = 30
  memory_size      = 256

  layers = [
    "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:${var.powertools_layer_version}"
  ]

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "spam-handler"
      POWERTOOLS_LOG_LEVEL    = "INFO"
      AWS_LAMBDA_LOG_FORMAT   = "JSON"
      SPAM_LOG_TABLE_NAME     = aws_dynamodb_table.spam_log.name
      SUPPRESSION_TABLE_NAME  = var.suppression_table_name
    }
  }

  tracing_config { mode = "Active" }

  tags = local.tags
}

resource "aws_lambda_permission" "ses_invoke_spam_handler" {
  # SESがこのLambdaを呼び出せるようにするリソースベースポリシー
  statement_id   = "AllowSESInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.spam_handler.function_name
  principal      = "ses.amazonaws.com"
  source_account = local.account_id
}

# ============================================================
# SES Receipt Rule Set
# ============================================================

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "mail-handson-receipt-rules"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  # 注意: リージョンごとにアクティブにできるルールセットは1つのみ
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

# ============================================================
# SES Receipt Rule（スパムチェック付き受信ルール）
# ============================================================

resource "aws_ses_receipt_rule" "with_spam_check" {
  # after = "" でルールセットの先頭に配置する
  # spam_handler の戻り値:
  #   CONTINUE      → S3保存アクションへ進む（クリーンメール）
  #   STOP_RULE_SET → ルールセット全体を停止（スパムはS3に保存しない）
  name          = "with-spam-check"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  after         = ""
  enabled       = true
  scan_enabled  = true
  recipients    = []

  lambda_action {
    function_arn    = aws_lambda_function.spam_handler.arn
    invocation_type = "RequestResponse"
    position        = 1
  }

  s3_action {
    bucket_name       = aws_s3_bucket.inbound_mail.id
    object_key_prefix = "inbound/"
    position          = 2
  }

  depends_on = [
    aws_s3_bucket_policy.inbound_mail,
    aws_lambda_permission.ses_invoke_spam_handler,
  ]
}

# ============================================================
# SES Receipt Rule（DMARCレポート受信）
# ============================================================

resource "aws_ses_receipt_rule" "dmarc_reports" {
  # 外部プロバイダー（Gmail, Yahoo等）が毎日送ってくるXML形式のDMARCレポートを
  # dmarc-reports@{domain} で受信してS3に保存する
  name          = "store-dmarc-reports"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  after         = aws_ses_receipt_rule.with_spam_check.name
  enabled       = true
  scan_enabled  = false
  recipients    = ["dmarc-reports@${var.domain_name}"]

  s3_action {
    bucket_name       = aws_s3_bucket.inbound_mail.id
    object_key_prefix = "dmarc-reports/"
    position          = 1
  }

  depends_on = [aws_s3_bucket_policy.inbound_mail]
}

resource "aws_ses_receipt_rule" "dmarc_forensic" {
  name          = "store-dmarc-forensic"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  after         = aws_ses_receipt_rule.dmarc_reports.name
  enabled       = true
  scan_enabled  = false
  recipients    = ["dmarc-forensic@${var.domain_name}"]

  s3_action {
    bucket_name       = aws_s3_bucket.inbound_mail.id
    object_key_prefix = "dmarc-forensic/"
    position          = 1
  }

  depends_on = [aws_s3_bucket_policy.inbound_mail]
}
