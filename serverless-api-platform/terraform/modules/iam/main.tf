# terraform/modules/iam/main.tf
#
# Lambda 実行ロールの定義。
# 最小権限の原則に従い、各 Lambda に必要な権限のみを付与する。
# * (ワイルドカード) のリソース指定は禁止（CLAUDE.md の禁止事項）。

locals {
  # Lambda 関数名と必要な権限のマッピング
  # 書き込み系 Lambda には dynamodb:PutItem, UpdateItem, DeleteItem を付与
  lambda_configs = {
    "list-items" = {
      dynamodb_actions = [
        "dynamodb:Query",
      ]
    }
    "get-item" = {
      dynamodb_actions = [
        "dynamodb:GetItem",
      ]
    }
    "create-item" = {
      dynamodb_actions = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
      ]
    }
    "update-item" = {
      dynamodb_actions = [
        "dynamodb:UpdateItem",
        "dynamodb:GetItem",
      ]
    }
    "delete-item" = {
      dynamodb_actions = [
        "dynamodb:DeleteItem",
        "dynamodb:GetItem",
      ]
    }
    "stream-processor" = {
      dynamodb_actions = [
        "dynamodb:GetShardIterator",
        "dynamodb:GetRecords",
        "dynamodb:ListStreams",
        "dynamodb:DescribeStream",
      ]
    }
  }
}

# 各 Lambda 関数の実行ロール
resource "aws_iam_role" "lambda" {
  for_each = local.lambda_configs

  # 命名規則: sap-<env>-<lambda名>-role
  name = "${var.prefix}-${each.key}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# CloudWatch Logs への書き込み権限（全 Lambda 共通）
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  for_each = local.lambda_configs

  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# X-Ray トレーシング権限（全 Lambda 共通）
resource "aws_iam_role_policy_attachment" "lambda_xray" {
  for_each = local.lambda_configs

  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# DynamoDB 操作権限（各 Lambda に個別設定）
resource "aws_iam_role_policy" "dynamodb" {
  for_each = local.lambda_configs

  name = "${var.prefix}-${each.key}-dynamodb-policy"
  role = aws_iam_role.lambda[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = each.value.dynamodb_actions
        # テーブル ARN と GSI ARN を両方指定
        Resource = [
          var.dynamodb_table_arn,
          "${var.dynamodb_table_arn}/index/*",
          "${var.dynamodb_table_arn}/stream/*",
        ]
      }
    ]
  })
}

# S3 への書き込み権限（stream-processor のみ）
# 監査ログバケット以外への書き込みを禁止するため、リソースを明示的に指定する（ワイルドカード禁止）。
resource "aws_iam_role_policy" "s3_audit" {
  name = "${var.prefix}-stream-processor-s3-policy"
  role = aws_iam_role.lambda["stream-processor"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
        ]
        Resource = "${var.audit_bucket_arn}/*"
      }
    ]
  })
}

# KMS 暗号化権限（stream-processor のみ）
# 監査ログ用 S3 バケットは SSE-KMS で暗号化されている。
# S3 の PutObject 時、S3 は Lambda の実行ロールで kms:GenerateDataKey を呼び出す。
# この権限がないと PutObject は AccessDenied で失敗する。
# kms:Decrypt は不要（PutObject のみ行うため）。
resource "aws_iam_role_policy" "kms_audit" {
  name = "${var.prefix}-stream-processor-kms-policy"
  role = aws_iam_role.lambda["stream-processor"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
        ]
        # 監査ログバケット専用の KMS キーのみに限定する（ワイルドカード禁止）
        Resource = var.audit_kms_key_arn
      }
    ]
  })
}
