locals {
  lambda_src_root = "${path.root}/../lambda"
  runtime         = "python3.12"
  architecture    = "arm64"
}

# ============================================================
# incident_investigator
# ============================================================

resource "aws_iam_role" "incident_investigator" {
  name = "${var.prefix}-incident-investigator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "incident_investigator_basic" {
  role       = aws_iam_role.incident_investigator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "incident_investigator_xray_write" {
  role       = aws_iam_role.incident_investigator.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "incident_investigator_inline" {
  name = "${var.prefix}-incident-investigator-inline"
  role = aws_iam_role.incident_investigator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SSMRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/bmao/*"
      },
      {
        Sid    = "CloudWatchInvestigate"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricStatistics",
        ]
        Resource = "*"
      },
      {
        Sid    = "XRayInvestigate"
        Effect = "Allow"
        Action = [
          "xray:GetServiceGraph",
          "xray:GetTraceSummaries",
        ]
        Resource = "*"
      },
      {
        Sid    = "ConfigInvestigate"
        Effect = "Allow"
        Action = [
          "config:GetComplianceSummaryByConfigRule",
          "config:GetComplianceDetailsByConfigRule",
        ]
        Resource = "*"
      },
    ]
  })
}

data "archive_file" "incident_investigator" {
  type        = "zip"
  source_dir  = "${local.lambda_src_root}/incident_investigator"
  output_path = "${path.module}/.dist/incident_investigator.zip"
}

resource "aws_lambda_function" "incident_investigator" {
  function_name    = "${var.prefix}-incident-investigator"
  description      = "CloudWatch/X-Ray/Config調査 Action Group Lambda"
  role             = aws_iam_role.incident_investigator.arn
  runtime          = local.runtime
  architectures    = [local.architecture]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.incident_investigator.output_path
  source_code_hash = data.archive_file.incident_investigator.output_base64sha256
  timeout          = 300

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME      = "bmao-incident-investigator"
      POWERTOOLS_METRICS_NAMESPACE = "bmao/incident_investigator"
      LOG_LEVEL                    = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "incident_investigator_bedrock" {
  statement_id  = "AllowBedrockAgent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.incident_investigator.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:ap-northeast-1:${var.account_id}:agent/*"
}

# ============================================================
# cost_optimizer
# ============================================================

resource "aws_iam_role" "cost_optimizer" {
  name = "${var.prefix}-cost-optimizer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "cost_optimizer_basic" {
  role       = aws_iam_role.cost_optimizer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "cost_optimizer_xray_write" {
  role       = aws_iam_role.cost_optimizer.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "cost_optimizer_inline" {
  name = "${var.prefix}-cost-optimizer-inline"
  role = aws_iam_role.cost_optimizer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SSMRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/bmao/*"
      },
      {
        Sid    = "CostExplorer"
        Effect = "Allow"
        Action = [
          "ce:GetAnomalies",
          "ce:GetRightsizingRecommendation",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2ReadOnly"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeAddresses",
        ]
        Resource = "*"
      },
    ]
  })
}

data "archive_file" "cost_optimizer" {
  type        = "zip"
  source_dir  = "${local.lambda_src_root}/cost_optimizer"
  output_path = "${path.module}/.dist/cost_optimizer.zip"
}

resource "aws_lambda_function" "cost_optimizer" {
  function_name    = "${var.prefix}-cost-optimizer"
  description      = "Cost Explorer/EC2コスト最適化調査 Action Group Lambda"
  role             = aws_iam_role.cost_optimizer.arn
  runtime          = local.runtime
  architectures    = [local.architecture]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.cost_optimizer.output_path
  source_code_hash = data.archive_file.cost_optimizer.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME      = "bmao-cost-optimizer"
      POWERTOOLS_METRICS_NAMESPACE = "bmao/cost_optimizer"
      LOG_LEVEL                    = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "cost_optimizer_bedrock" {
  statement_id  = "AllowBedrockAgent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_optimizer.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:ap-northeast-1:${var.account_id}:agent/*"
}

# ============================================================
# remediation（破壊的権限は意図的に除外）
# ============================================================

resource "aws_iam_role" "remediation" {
  name = "${var.prefix}-remediation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "remediation_basic" {
  role       = aws_iam_role.remediation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "remediation_xray_write" {
  role       = aws_iam_role.remediation.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "remediation_inline" {
  name = "${var.prefix}-remediation-inline"
  role = aws_iam_role.remediation.id

  # 禁止: iam:*, organizations:*, ec2:TerminateInstances, rds:DeleteDBInstance
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SSMRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/bmao/*"
      },
      {
        Sid    = "ApprovalRequestTable"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
        ]
        Resource = "arn:aws:dynamodb:ap-northeast-1:${var.account_id}:table/${var.dynamodb_approval_requests_table_name}"
      },
      {
        Sid    = "ExecutionHistoryTable"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
        ]
        Resource = "arn:aws:dynamodb:ap-northeast-1:${var.account_id}:table/${var.dynamodb_execution_history_table_name}"
      },
      {
        Sid    = "SSMRunCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
    ]
  })
}

data "archive_file" "remediation" {
  type        = "zip"
  source_dir  = "${local.lambda_src_root}/remediation"
  output_path = "${path.module}/.dist/remediation.zip"
}

resource "aws_lambda_function" "remediation" {
  function_name    = "${var.prefix}-remediation"
  description      = "承認フロー経由のSSMコマンド実行 Action Group Lambda"
  role             = aws_iam_role.remediation.arn
  runtime          = local.runtime
  architectures    = [local.architecture]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.remediation.output_path
  source_code_hash = data.archive_file.remediation.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME      = "bmao-remediation"
      POWERTOOLS_METRICS_NAMESPACE = "bmao/remediation"
      LOG_LEVEL                    = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "remediation_bedrock" {
  statement_id  = "AllowBedrockAgent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:ap-northeast-1:${var.account_id}:agent/*"
}

# ============================================================
# reporter
# ============================================================

resource "aws_iam_role" "reporter" {
  name = "${var.prefix}-reporter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "reporter_basic" {
  role       = aws_iam_role.reporter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "reporter_xray_write" {
  role       = aws_iam_role.reporter.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "reporter_inline" {
  name = "${var.prefix}-reporter-inline"
  role = aws_iam_role.reporter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SSMRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/bmao/*"
      },
      {
        Sid      = "S3ReportWrite"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "arn:aws:s3:::${var.s3_reports_bucket_name}/*"
      },
    ]
  })
}

data "archive_file" "reporter" {
  type        = "zip"
  source_dir  = "${local.lambda_src_root}/reporter"
  output_path = "${path.module}/.dist/reporter.zip"
}

resource "aws_lambda_function" "reporter" {
  function_name    = "${var.prefix}-reporter"
  description      = "HTMLレポート生成・Chatwork通知 Action Group Lambda"
  role             = aws_iam_role.reporter.arn
  runtime          = local.runtime
  architectures    = [local.architecture]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.reporter.output_path
  source_code_hash = data.archive_file.reporter.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME      = "bmao-reporter"
      POWERTOOLS_METRICS_NAMESPACE = "bmao/reporter"
      LOG_LEVEL                    = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = var.common_tags
}

resource "aws_lambda_permission" "reporter_bedrock" {
  statement_id  = "AllowBedrockAgent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reporter.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:ap-northeast-1:${var.account_id}:agent/*"
}
