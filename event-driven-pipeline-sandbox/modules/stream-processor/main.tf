locals {
  name_prefix   = "${var.project}-${var.environment}"
  function_name = "${local.name_prefix}-stream-processor"
}

# -----------------------------------------------------------------
# Lambda デプロイパッケージ
# -----------------------------------------------------------------
data "archive_file" "stream_processor" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/stream_processor.zip"
}

# -----------------------------------------------------------------
# IAM Role
# -----------------------------------------------------------------
resource "aws_iam_role" "stream_processor" {
  name = "${local.name_prefix}-stream-processor-role"

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

resource "aws_iam_role_policy" "stream_processor" {
  name = "${local.name_prefix}-stream-processor-policy"
  role = aws_iam_role.stream_processor.id

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
      # DynamoDB Streams: 読み取り
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams",
        ]
        Resource = var.jobs_table_stream_arn
      },
      # メトリクステーブル: 集計書き込み
      {
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem",
          "dynamodb:PutItem",
        ]
        Resource = var.metrics_table_arn
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
resource "aws_security_group" "stream_processor" {
  name        = "${local.function_name}-sg"
  description = "Security group for stream-processor Lambda"
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
resource "aws_cloudwatch_log_group" "stream_processor" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 14
}

# -----------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------
resource "aws_lambda_function" "stream_processor" {
  function_name = local.function_name
  role          = aws_iam_role.stream_processor.arn
  runtime       = "python3.12"
  handler       = "index.handler"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.stream_processor.output_path
  source_code_hash = data.archive_file.stream_processor.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.stream_processor.id]
  }

  environment {
    variables = {
      METRICS_TABLE_NAME    = var.metrics_table_name
      METRICS_RETENTION_DAYS = tostring(var.metrics_retention_days)
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.stream_processor]

  tags = {
    Name = local.function_name
  }
}

# -----------------------------------------------------------------
# DynamoDB Streams Event Source Mapping
# フィルタ: status が COMPLETED または FAILED に変わった MODIFY イベントのみ処理
# -----------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
  event_source_arn  = var.jobs_table_stream_arn
  function_name     = aws_lambda_function.stream_processor.arn
  starting_position = "LATEST"
  batch_size        = var.batch_size

  # フィルタリング: status が COMPLETED か FAILED の MODIFY イベントのみ Lambda を起動
  # 不要な起動を省くことでコストと処理量を削減
  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["MODIFY"]
        dynamodb = {
          NewImage = {
            status = {
              S = ["COMPLETED", "FAILED"]
            }
          }
        }
      })
    }
  }
}
