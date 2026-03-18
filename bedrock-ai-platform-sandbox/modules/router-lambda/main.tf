locals {
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------
# Lambda ソースコードのパッケージング
# -----------------------------------------------------------------
data "archive_file" "router_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/router_lambda.zip"
}

# -----------------------------------------------------------------
# Security Group for Router Lambda
# -----------------------------------------------------------------
resource "aws_security_group" "router_lambda" {
  name        = "${local.name_prefix}-router-lambda-sg"
  description = "Security group for Router Lambda function"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to VPC (Bedrock/DynamoDB endpoints)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  tags = {
    Name = "${local.name_prefix}-router-lambda-sg"
  }
}

# -----------------------------------------------------------------
# CloudWatch Log Group（Lambda ログ）
# -----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "router_lambda" {
  name              = "/aws/lambda/${local.name_prefix}-router"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-router-lambda-logs"
  }
}

# -----------------------------------------------------------------
# IAM Role for Router Lambda
# -----------------------------------------------------------------
resource "aws_iam_role" "router_lambda" {
  name        = "${local.name_prefix}-router-lambda-role"
  description = "Execution role for the Router Lambda function"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowLambdaAssume"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = {
    Name = "${local.name_prefix}-router-lambda-role"
  }
}

resource "aws_iam_policy" "router_lambda" {
  name        = "${local.name_prefix}-router-lambda-policy"
  description = "Policy for Router Lambda: Bedrock, DynamoDB, VPC, X-Ray"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudWatch Logs（ロググループを明示して最小権限）
      {
        Sid    = "AllowLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.router_lambda.arn}:*"
      },
      # VPC ネットワーキング（ENI 操作）
      {
        Sid    = "AllowVPCNetworking"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = "*"
      },
      # Bedrock モデル呼び出し（許可モデルのみ）
      {
        Sid    = "AllowBedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = var.allowed_model_arns
      },
      # Guardrails 適用
      {
        Sid      = "AllowGuardrail"
        Effect   = "Allow"
        Action   = ["bedrock:ApplyGuardrail"]
        Resource = [var.guardrail_arn]
      },
      # DynamoDB: テナント設定読み取り
      {
        Sid    = "AllowTenantRead"
        Effect = "Allow"
        Action = ["dynamodb:GetItem"]
        Resource = [var.tenant_table_arn]
      },
      # DynamoDB: 使用量集計の読み書き
      {
        Sid    = "AllowUsageWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
        ]
        Resource = [var.usage_table_arn]
      },
      # X-Ray トレーシング
      {
        Sid    = "AllowXRay"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
        ]
        Resource = "*"
      },
    ]
  })

  tags = {
    Name = "${local.name_prefix}-router-lambda-policy"
  }
}

resource "aws_iam_role_policy_attachment" "router_lambda" {
  role       = aws_iam_role.router_lambda.name
  policy_arn = aws_iam_policy.router_lambda.arn
}

# -----------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------
resource "aws_lambda_function" "router" {
  function_name    = "${local.name_prefix}-router"
  description      = "Intelligent router: classifies prompt complexity and routes to Haiku or Sonnet"
  role             = aws_iam_role.router_lambda.arn
  handler          = "index.lambda_handler"
  runtime          = "python3.12"
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout
  filename         = data.archive_file.router_lambda.output_path
  source_code_hash = data.archive_file.router_lambda.output_base64sha256

  environment {
    variables = {
      TENANT_TABLE    = var.tenant_table_name
      USAGE_TABLE     = var.usage_table_name
      GUARDRAIL_ID    = var.guardrail_id
      GUARDRAIL_VERSION = var.guardrail_version
      HAIKU_MODEL_ID  = var.haiku_model_id
      SONNET_MODEL_ID = var.sonnet_model_id
    }
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.router_lambda.id]
  }

  # X-Ray アクティブトレーシング（observability モジュール準備）
  tracing_config {
    mode = "Active"
  }

  # ログ出力先を明示（Terraform 管理のロググループに誘導）
  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.router_lambda.name
  }

  tags = {
    Name = "${local.name_prefix}-router"
  }

  depends_on = [
    aws_iam_role_policy_attachment.router_lambda,
    aws_cloudwatch_log_group.router_lambda,
  ]
}
