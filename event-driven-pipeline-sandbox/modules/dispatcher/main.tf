locals {
  name_prefix   = "${var.project}-${var.environment}"
  function_name = "${local.name_prefix}-dispatcher"
}

# -----------------------------------------------------------------
# Lambda デプロイパッケージ
# -----------------------------------------------------------------
data "archive_file" "dispatcher" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/dispatcher.zip"
}

# -----------------------------------------------------------------
# IAM Role for Dispatcher Lambda
# -----------------------------------------------------------------
resource "aws_iam_role" "dispatcher" {
  name = "${local.name_prefix}-dispatcher-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "dispatcher" {
  name = "${local.name_prefix}-dispatcher-policy"
  role = aws_iam_role.dispatcher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/${local.function_name}:*"
      },
      # SQS: event source mapping でメッセージを受信・削除
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility",
        ]
        Resource = var.input_queue_arn
      },
      # DynamoDB: ジョブレコード書き込み
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
        ]
        Resource = var.jobs_table_arn
      },
      # Step Functions: 実行開始
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = var.state_machine_arn
      },
      # VPC: ENI 作成・削除
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = "*"
      },
      # X-Ray トレーシング
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------
# Security Group for Dispatcher Lambda
# -----------------------------------------------------------------
resource "aws_security_group" "dispatcher" {
  name        = "${local.function_name}-sg"
  description = "Security group for dispatcher Lambda"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to AWS endpoints (VPC endpoints / NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.function_name}-sg"
  }
}

# -----------------------------------------------------------------
# CloudWatch Log Group
# -----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "dispatcher" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 14
}

# -----------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------
resource "aws_lambda_function" "dispatcher" {
  function_name = local.function_name
  role          = aws_iam_role.dispatcher.arn
  runtime       = "python3.12"
  handler       = "index.handler"
  timeout       = var.lambda_timeout_seconds
  memory_size   = 256

  filename         = data.archive_file.dispatcher.output_path
  source_code_hash = data.archive_file.dispatcher.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.dispatcher.id]
  }

  environment {
    variables = {
      JOBS_TABLE_NAME   = var.jobs_table_name
      STATE_MACHINE_ARN = var.state_machine_arn
      JOB_RETENTION_DAYS = tostring(var.job_retention_days)
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.dispatcher]

  tags = {
    Name = local.function_name
  }
}

# -----------------------------------------------------------------
# SQS Event Source Mapping
# Lambda が SQS をポーリングしてバッチ処理する
# report_batch_item_failures = true で部分バッチ失敗を有効化
# -----------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = var.input_queue_arn
  function_name                      = aws_lambda_function.dispatcher.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = 5 # 最大 5 秒待って batch_size 分まとめる

  function_response_types = ["ReportBatchItemFailures"] # 部分バッチ失敗を有効化

  scaling_config {
    maximum_concurrency = 5 # 同時実行数上限（SFN のスロットリング対策）
  }
}
