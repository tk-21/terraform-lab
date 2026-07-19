# ─────────────────────────────────────────────────────────────────────────────
# Lambda Layer: 共有モジュール (audit_logger + chatwork_notifier)
# ─────────────────────────────────────────────────────────────────────────────

# python/ プレフィックスを付けてzipすることで /opt/python/ にマウントされる
data "archive_file" "shared_layer" {
  type        = "zip"
  output_path = "${path.module}/../../../lambda/shared_layer.zip"

  source {
    content  = file("${path.module}/../../../lambda/shared/audit_logger.py")
    filename = "python/audit_logger.py"
  }

  source {
    content  = file("${path.module}/../../../lambda/shared/chatwork_notifier.py")
    filename = "python/chatwork_notifier.py"
  }
}

resource "aws_lambda_layer_version" "csar_shared" {
  layer_name               = "csar-shared-modules"
  filename                 = data.archive_file.shared_layer.output_path
  source_code_hash         = data.archive_file.shared_layer.output_base64sha256
  compatible_runtimes      = ["python3.12"]
  compatible_architectures = ["arm64"]
  description              = "CSAR共有モジュール: audit_logger + chatwork_notifier"
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda Layer: Lambda Powertools (AWS公開Layer)
# arm64 / python3.12 用の公開Layer ARNを使用する
# ─────────────────────────────────────────────────────────────────────────────

locals {
  powertools_layer_arn = "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:${var.powertools_layer_version}"

  # 全Lambda共通の環境変数
  lambda_common_env = {
    LOG_LEVEL             = "INFO"
    AWS_LAMBDA_LOG_FORMAT = "JSON"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 修復 Lambda
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "s3_remediation" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/remediation/s3_remediation/index.py"
  output_path = "${path.module}/../../../lambda/s3_remediation.zip"
}

resource "aws_lambda_function" "s3_remediation" {
  function_name    = "csar-remediation-s3"
  role             = var.lambda_role_arn
  handler          = "index.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"] # Graviton2: x86_64比20%コスト削減
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.s3_remediation.output_path
  source_code_hash = data.archive_file.s3_remediation.output_base64sha256

  layers = [
    aws_lambda_layer_version.csar_shared.arn,
    local.powertools_layer_arn,
  ]

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = merge(local.lambda_common_env, {
      DYNAMODB_TABLE_NAME     = var.dynamodb_table_name
      AUDIT_BUCKET_NAME       = var.audit_bucket_name
      POWERTOOLS_SERVICE_NAME = "csar-remediation-s3"
    })
  }

  dead_letter_config {
    target_arn = var.dlq_arn
  }

  # 同時実行数上限: 修復Lambdaの暴走防止 (Config Rule再評価ループ対策)
  reserved_concurrent_executions = 10

  tracing_config {
    mode = "Active"
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "s3_config_rule" {
  statement_id  = "AllowEventBridgeConfigRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.s3_config_rule_event_rule_arn
}

resource "aws_lambda_permission" "s3_custom_action" {
  statement_id  = "AllowEventBridgeCustomAction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.s3_custom_action_event_rule_arn
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM 修復 Lambda
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "iam_remediation" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/remediation/iam_remediation/index.py"
  output_path = "${path.module}/../../../lambda/iam_remediation.zip"
}

resource "aws_lambda_function" "iam_remediation" {
  function_name    = "csar-remediation-iam"
  role             = var.lambda_role_arn
  handler          = "index.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.iam_remediation.output_path
  source_code_hash = data.archive_file.iam_remediation.output_base64sha256

  layers = [
    aws_lambda_layer_version.csar_shared.arn,
    local.powertools_layer_arn,
  ]

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = merge(local.lambda_common_env, {
      DYNAMODB_TABLE_NAME     = var.dynamodb_table_name
      AUDIT_BUCKET_NAME       = var.audit_bucket_name
      POWERTOOLS_SERVICE_NAME = "csar-remediation-iam"
    })
  }

  dead_letter_config {
    target_arn = var.dlq_arn
  }

  reserved_concurrent_executions = 10

  tracing_config {
    mode = "Active"
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "iam_config_rule" {
  statement_id  = "AllowEventBridgeConfigRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.iam_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.iam_config_rule_event_rule_arn
}

resource "aws_lambda_permission" "iam_custom_action" {
  statement_id  = "AllowEventBridgeCustomAction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.iam_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.iam_custom_action_event_rule_arn
}

# ─────────────────────────────────────────────────────────────────────────────
# EC2/Security Group 修復 Lambda
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "sg_remediation" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/remediation/ec2_sg_remediation/index.py"
  output_path = "${path.module}/../../../lambda/sg_remediation.zip"
}

resource "aws_lambda_function" "sg_remediation" {
  function_name    = "csar-remediation-ec2-sg"
  role             = var.lambda_role_arn
  handler          = "index.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.sg_remediation.output_path
  source_code_hash = data.archive_file.sg_remediation.output_base64sha256

  layers = [
    aws_lambda_layer_version.csar_shared.arn,
    local.powertools_layer_arn,
  ]

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = merge(local.lambda_common_env, {
      DYNAMODB_TABLE_NAME     = var.dynamodb_table_name
      AUDIT_BUCKET_NAME       = var.audit_bucket_name
      POWERTOOLS_SERVICE_NAME = "csar-remediation-ec2-sg"
    })
  }

  dead_letter_config {
    target_arn = var.dlq_arn
  }

  reserved_concurrent_executions = 10

  tracing_config {
    mode = "Active"
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "sg_config_rule" {
  statement_id  = "AllowEventBridgeConfigRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sg_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.sg_config_rule_event_rule_arn
}

resource "aws_lambda_permission" "sg_custom_action" {
  statement_id  = "AllowEventBridgeCustomAction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sg_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.sg_custom_action_event_rule_arn
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS 修復 Lambda
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "rds_remediation" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/remediation/rds_remediation/index.py"
  output_path = "${path.module}/../../../lambda/rds_remediation.zip"
}

resource "aws_lambda_function" "rds_remediation" {
  function_name    = "csar-remediation-rds"
  role             = var.lambda_role_arn
  handler          = "index.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.rds_remediation.output_path
  source_code_hash = data.archive_file.rds_remediation.output_base64sha256

  layers = [
    aws_lambda_layer_version.csar_shared.arn,
    local.powertools_layer_arn,
  ]

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = merge(local.lambda_common_env, {
      DYNAMODB_TABLE_NAME     = var.dynamodb_table_name
      AUDIT_BUCKET_NAME       = var.audit_bucket_name
      POWERTOOLS_SERVICE_NAME = "csar-remediation-rds"
    })
  }

  dead_letter_config {
    target_arn = var.dlq_arn
  }

  reserved_concurrent_executions = 10

  tracing_config {
    mode = "Active"
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "rds_config_rule" {
  statement_id  = "AllowEventBridgeConfigRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.rds_config_rule_event_rule_arn
}

resource "aws_lambda_permission" "rds_custom_action" {
  statement_id  = "AllowEventBridgeCustomAction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.rds_custom_action_event_rule_arn
}
