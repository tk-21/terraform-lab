locals {
  name_prefix   = "${var.project}-${var.environment}"
  function_name = "${local.name_prefix}-dlq-handler"
}

# -----------------------------------------------------------------
# Lambda デプロイパッケージ
# -----------------------------------------------------------------
data "archive_file" "dlq_handler" {
  type        = "zip"
  source_file = "${path.module}/src/dlq_handler.py"
  output_path = "${path.module}/dist/dlq_handler.zip"
}

# -----------------------------------------------------------------
# IAM Role
# -----------------------------------------------------------------
resource "aws_iam_role" "dlq_handler" {
  name = "${local.name_prefix}-dlq-handler-role"

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

resource "aws_iam_role_policy" "dlq_handler" {
  name = "${local.name_prefix}-dlq-handler-policy"
  role = aws_iam_role.dlq_handler.id

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
      # DynamoDB: ジョブステータス更新 + GSI クエリ（停滞ジョブ検索）
      {
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem",
          "dynamodb:Query",
        ]
        Resource = [
          var.jobs_table_arn,
          "${var.jobs_table_arn}/index/*",
        ]
      },
      # SNS: アラート送信
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.alert_topic_arn
      },
      # VPC: ENI 操作
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = "*"
      },
      # X-Ray
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
# Security Group
# -----------------------------------------------------------------
resource "aws_security_group" "dlq_handler" {
  name        = "${local.function_name}-sg"
  description = "Security group for DLQ handler Lambda"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to AWS endpoints (VPC endpoints)"
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
resource "aws_cloudwatch_log_group" "dlq_handler" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 14
}

# -----------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------
resource "aws_lambda_function" "dlq_handler" {
  function_name = local.function_name
  role          = aws_iam_role.dlq_handler.arn
  runtime       = "python3.12"
  handler       = "dlq_handler.handler"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.dlq_handler.output_path
  source_code_hash = data.archive_file.dlq_handler.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.dlq_handler.id]
  }

  environment {
    variables = {
      JOBS_TABLE_NAME = var.jobs_table_name
      ALERT_TOPIC_ARN = var.alert_topic_arn
      STUCK_JOB_HOURS = tostring(var.stuck_job_hours)
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.dlq_handler]

  tags = {
    Name = local.function_name
  }
}

# EventBridge が Lambda を呼べる権限
resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dlq_handler.function_name
  principal     = "events.amazonaws.com"
}

# -----------------------------------------------------------------
# EventBridge Rule 1: Step Functions 実行失敗を検知
# Step Functions は実行ステータスが変わると自動で EventBridge にイベントを送る
# -----------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "sfn_failure" {
  name        = "${local.name_prefix}-sfn-failure"
  description = "Capture Step Functions FAILED/TIMED_OUT/ABORTED executions"

  event_pattern = jsonencode({
    source      = ["aws.states"]
    detail-type = ["Step Functions Execution Status Change"]
    detail = {
      stateMachineArn = [var.state_machine_arn]
      status          = ["FAILED", "TIMED_OUT", "ABORTED"]
    }
  })

  tags = {
    Name = "${local.name_prefix}-sfn-failure"
  }
}

resource "aws_cloudwatch_event_target" "sfn_failure_to_lambda" {
  rule = aws_cloudwatch_event_rule.sfn_failure.name
  arn  = aws_lambda_function.dlq_handler.arn
}

# -----------------------------------------------------------------
# EventBridge Rule 2: スケジュール実行（停滞ジョブ検出）
# cron または rate 式で定期的に Cleanup を実行する
# -----------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "cleanup_schedule" {
  name                = "${local.name_prefix}-cleanup-schedule"
  description         = "Periodically detect and mark stuck PENDING jobs"
  schedule_expression = var.cleanup_schedule

  tags = {
    Name = "${local.name_prefix}-cleanup-schedule"
  }
}

resource "aws_cloudwatch_event_target" "cleanup_to_lambda" {
  rule = aws_cloudwatch_event_rule.cleanup_schedule.name
  arn  = aws_lambda_function.dlq_handler.arn
}
