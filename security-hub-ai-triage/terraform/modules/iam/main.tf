data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.project_name}-lambda-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

data "aws_iam_policy_document" "lambda_policy" {
  # Bedrock: モデル呼び出し（対象モデルの ARN のみ）
  statement {
    sid    = "BedrockInvokeModel"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel"
    ]
    resources = [
      "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}"
    ]
  }

  # DynamoDB: 重複排除テーブルへの読み書き（テーブル ARN のみ）
  statement {
    sid    = "DynamoDBDedup"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem"
    ]
    resources = [
      var.dynamodb_table_arn
    ]
  }

  # S3: レポート保存バケットへのオブジェクト書き込み（バケット ARN/* のみ）
  statement {
    sid    = "S3PutReport"
    effect = "Allow"
    actions = [
      "s3:PutObject"
    ]
    resources = [
      "${var.s3_bucket_arn}/*"
    ]
  }

  # CloudWatch Logs: ログ書き込み
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-*"
    ]
  }

  # Secrets Manager: Chatwork トークン取得（指定 ARN のみ）
  statement {
    sid    = "SecretsManagerGetChatwork"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      var.chatwork_secret_arn
    ]
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name   = "${var.project_name}-lambda-policy-${var.environment}"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}
