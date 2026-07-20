# -------------------------------------------------------
# IAM ロール (Lambda 共通)
# -------------------------------------------------------

resource "aws_iam_role" "lambda_exec" {
  name = "${var.project}-lambda-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.common_tags, { Name = "${var.project}-lambda-exec-role" })
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${var.project}-lambda-dynamodb-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        # なぜ: 対象テーブルのみに絞りワイルドカード使用を回避
        Resource = [
          var.dynamodb_table_arn,
          "${var.dynamodb_table_arn}/index/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_sqs_dlq" {
  name = "${var.project}-lambda-sqs-dlq-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        # なぜ: DLQ のみに限定し、他のキューへのアクセスを禁止
        Resource = [var.orders_dlq_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_logs" {
  name = "${var.project}-lambda-logs-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_xray" {
  name = "${var.project}-lambda-xray-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_vpc_eni" {
  name = "${var.project}-lambda-vpc-eni-policy"
  role = aws_iam_role.lambda_exec.id

  # なぜ: VPC 内 Lambda はネットワークインターフェース作成権限が必要
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------
# セキュリティグループ (Lambda 用)
# -------------------------------------------------------

resource "aws_security_group" "lambda" {
  name   = "${var.project}-lambda-sg"
  vpc_id = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # なぜ: VPC Endpoint への HTTPS 通信を許可
  }

  tags = merge(var.common_tags, { Name = "${var.project}-lambda-sg" })
}

# -------------------------------------------------------
# zip パッケージング
# -------------------------------------------------------

data "archive_file" "inventory_check" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/inventory-check"
  output_path = "${path.root}/../.build/inventory-check.zip"
}

data "archive_file" "notification" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/notification"
  output_path = "${path.root}/../.build/notification.zip"
}

data "archive_file" "dlq_reprocessor" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/dlq-reprocessor"
  output_path = "${path.root}/../.build/dlq-reprocessor.zip"
}

# -------------------------------------------------------
# CloudWatch Log Groups
# -------------------------------------------------------

resource "aws_cloudwatch_log_group" "inventory_check" {
  name              = "/aws/lambda/${var.project}-inventory-check"
  retention_in_days = 7 # なぜ: dev 環境はコスト削減のため短期保存

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "notification" {
  name              = "/aws/lambda/${var.project}-notification"
  retention_in_days = 7

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "dlq_reprocessor" {
  name              = "/aws/lambda/${var.project}-dlq-reprocessor"
  retention_in_days = 7

  tags = var.common_tags
}

# -------------------------------------------------------
# Lambda 関数: 在庫確認
# -------------------------------------------------------

resource "aws_lambda_function" "inventory_check" {
  function_name = "${var.project}-inventory-check"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "app.handler"
  runtime       = "python3.12"
  architectures = ["arm64"] # なぜ: x86_64 比で約 20% コスト削減
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.inventory_check.output_path
  source_code_hash = data.archive_file.inventory_check.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "Active" # なぜ: X-Ray でボトルネックを可視化するため
  }

  environment {
    variables = {
      DYNAMODB_TABLE_NAME     = var.dynamodb_table_name
      POWERTOOLS_SERVICE_NAME = "${var.project}-inventory-check"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.inventory_check,
    aws_iam_role_policy.lambda_logs
  ]

  tags = merge(var.common_tags, { Name = "${var.project}-inventory-check" })
}

# -------------------------------------------------------
# Lambda 関数: 通知
# -------------------------------------------------------

resource "aws_lambda_function" "notification" {
  function_name = "${var.project}-notification"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "app.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.notification.output_path
  source_code_hash = data.archive_file.notification.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DYNAMODB_TABLE_NAME     = var.dynamodb_table_name
      POWERTOOLS_SERVICE_NAME = "${var.project}-notification"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.notification,
    aws_iam_role_policy.lambda_logs
  ]

  tags = merge(var.common_tags, { Name = "${var.project}-notification" })
}

# -------------------------------------------------------
# Lambda 関数: DLQ 再処理
# -------------------------------------------------------

resource "aws_lambda_function" "dlq_reprocessor" {
  function_name = "${var.project}-dlq-reprocessor"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "app.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 60 # なぜ: DLQ 処理はバッチ数分のループがあるため長めに設定
  memory_size   = 256

  filename         = data.archive_file.dlq_reprocessor.output_path
  source_code_hash = data.archive_file.dlq_reprocessor.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DYNAMODB_TABLE_NAME     = var.dynamodb_table_name
      POWERTOOLS_SERVICE_NAME = "${var.project}-dlq-reprocessor"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.dlq_reprocessor,
    aws_iam_role_policy.lambda_logs,
    aws_iam_role_policy.lambda_sqs_dlq
  ]

  tags = merge(var.common_tags, { Name = "${var.project}-dlq-reprocessor" })
}

# -------------------------------------------------------
# SQS イベントソースマッピング: DLQ → dlq-reprocessor
# -------------------------------------------------------

resource "aws_lambda_event_source_mapping" "dlq" {
  event_source_arn                   = var.orders_dlq_arn
  function_name                      = aws_lambda_function.dlq_reprocessor.arn
  batch_size                         = 5 # なぜ: 一度に大量処理せず、失敗時の影響範囲を限定
  maximum_batching_window_in_seconds = 30

  # なぜ: 部分的なバッチ失敗を許可し、成功したメッセージは削除する
  function_response_types = ["ReportBatchItemFailures"]
}
