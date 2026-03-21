data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "archive_file" "aws_inspector" {
  type        = "zip"
  source_dir  = "${path.module}/src/aws_inspector"
  output_path = "${path.module}/aws_inspector.zip"
}

data "archive_file" "report_writer" {
  type        = "zip"
  source_dir  = "${path.module}/src/report_writer"
  output_path = "${path.module}/report_writer.zip"
}

data "archive_file" "notifier" {
  type        = "zip"
  source_dir  = "${path.module}/src/notifier"
  output_path = "${path.module}/notifier.zip"
}

# ─── IAM: aws_inspector ───────────────────────────────────────────────────────

resource "aws_iam_role" "aws_inspector" {
  name = "bedrock-agent-aws-inspector-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws_inspector_basic" {
  role       = aws_iam_role.aws_inspector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "aws_inspector_custom" {
  name = "aws-inspector-policy"
  role = aws_iam_role.aws_inspector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = ["*"]
      }
    ]
  })
}

# ─── IAM: report_writer ───────────────────────────────────────────────────────

resource "aws_iam_role" "report_writer" {
  name = "bedrock-agent-report-writer-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "report_writer_basic" {
  role       = aws_iam_role.report_writer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "report_writer_custom" {
  name = "report-writer-policy"
  role = aws_iam_role.report_writer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [var.reports_bucket_arn, "${var.reports_bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

# ─── IAM: notifier ────────────────────────────────────────────────────────────

resource "aws_iam_role" "notifier" {
  name = "bedrock-agent-notifier-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "notifier_basic" {
  role       = aws_iam_role.notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "notifier_custom" {
  name = "notifier-policy"
  role = aws_iam_role.notifier.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = [var.sns_topic_arn]
    }]
  })
}

# ─── Lambda Functions ─────────────────────────────────────────────────────────

resource "aws_lambda_function" "aws_inspector" {
  function_name    = "bedrock-agent-aws-inspector"
  role             = aws_iam_role.aws_inspector.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.aws_inspector.output_path
  source_code_hash = data.archive_file.aws_inspector.output_base64sha256
  memory_size      = 256
  timeout          = 60
  environment {
    variables = { REGION = var.region }
  }
}

resource "aws_lambda_function" "report_writer" {
  function_name    = "bedrock-agent-report-writer"
  role             = aws_iam_role.report_writer.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.report_writer.output_path
  source_code_hash = data.archive_file.report_writer.output_base64sha256
  memory_size      = 256
  timeout          = 60
  environment {
    variables = { REPORTS_BUCKET_NAME = var.reports_bucket_name }
  }
}

resource "aws_lambda_function" "notifier" {
  function_name    = "bedrock-agent-notifier"
  role             = aws_iam_role.notifier.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256
  memory_size      = 256
  timeout          = 60
  environment {
    variables = {
      SNS_TOPIC_ARN = var.sns_topic_arn
      REGION        = var.region
    }
  }
}

# ─── Lambda permissions for Bedrock Agent ─────────────────────────────────────

resource "aws_lambda_permission" "aws_inspector_bedrock" {
  statement_id  = "AllowBedrockAgentInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_inspector.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agent/*"
}

resource "aws_lambda_permission" "report_writer_bedrock" {
  statement_id  = "AllowBedrockAgentInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report_writer.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agent/*"
}

resource "aws_lambda_permission" "notifier_bedrock" {
  statement_id  = "AllowBedrockAgentInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agent/*"
}
