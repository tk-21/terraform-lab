locals {
  region = "ap-northeast-1"
}

# ─────────────────────────────────────────────
# Lambda 修復実行ロール
# ─────────────────────────────────────────────

resource "aws_iam_role" "lambda_remediation" {
  # IAMロール名は64文字以内のAWSハード制限に注意
  name = "csar-lambda-remediation-role"
  # IAM Role descriptions accept only the AWS-supported character set.
  description = "Execution role for CSAR remediation Lambdas"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# VPC Lambda実行に必要なENI作成権限 (AWSマネージドポリシー)
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_remediation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# X-Rayトレーシング書き込み権限 (Lambda Powertools Tracer用)
resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda_remediation.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "lambda_remediation" {
  name = "csar-lambda-remediation-policy"
  role = aws_iam_role.lambda_remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3バケットのパブリックアクセスブロックとSSEを有効化する権限
        Sid    = "S3Remediation"
        Effect = "Allow"
        Action = [
          "s3:PutBucketPublicAccessBlock",
          "s3:PutEncryptionConfiguration",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetEncryptionConfiguration"
        ]
        Resource = "arn:aws:s3:::*"
      },
      {
        # IAMユーザーのMFA未設定時にコンソールアクセスを無効化する権限
        Sid    = "IAMRemediation"
        Effect = "Allow"
        Action = [
          "iam:UpdateLoginProfile",
          "iam:DeleteLoginProfile",
          "iam:ListMFADevices",
          "iam:GetUser",
          "iam:ListAttachedUserPolicies"
        ]
        Resource = "arn:aws:iam::*:user/*"
      },
      {
        # EC2 セキュリティグループのSSH開放ルールを削除する権限
        # DescribeSecurityGroupsはリソース指定不可のため"*"が必要
        Sid    = "EC2SGRemediation"
        Effect = "Allow"
        Action = [
          "ec2:DescribeSecurityGroups",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        # RDSインスタンスのパブリックアクセス無効化とスナップショット作成権限
        # CreateDBSnapshotはDBインスタンスとスナップショットの両リソースへの権限が必要
        Sid    = "RDSRemediation"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:ModifyDBInstance",
          "rds:CreateDBSnapshot"
        ]
        Resource = [
          "arn:aws:rds:${local.region}:*:db:*",
          "arn:aws:rds:${local.region}:*:snapshot:csar-snap-*"
        ]
      },
      {
        # 修復ログのDynamoDB書き込み権限
        Sid    = "AuditLog"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = "arn:aws:dynamodb:${local.region}:*:table/csar-remediation-log"
      },
      {
        # S3監査ログへの書き込み権限 (prefixを限定して最小権限を実現)
        Sid      = "S3AuditWrite"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.audit_bucket}/remediation-logs/*"
      },
      {
        # 修復失敗時にDLQへメッセージを送信する権限
        Sid      = "SQSDLQWrite"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = var.dlq_arn
      },
      {
        # Lambda Powertools Metrics (EMF) によるカスタムメトリクス送信権限
        # PutMetricDataはリソース指定不可
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────
# Config サービスロール
# ─────────────────────────────────────────────

resource "aws_iam_role" "config_service" {
  name        = "csar-config-service-role"
  description = "Service role for AWS Config"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# AWSが管理するConfigサービスロールポリシー (設定変更記録・評価に必要)
resource "aws_iam_role_policy_attachment" "config_service" {
  role       = aws_iam_role.config_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Configスナップショット/履歴をS3監査バケットへ書き込む追加権限
resource "aws_iam_role_policy" "config_s3_delivery" {
  name = "csar-config-s3-delivery-policy"
  role = aws_iam_role.config_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConfigS3Delivery"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketAcl"
        ]
        Resource = [
          "arn:aws:s3:::${var.audit_bucket}",
          "arn:aws:s3:::${var.audit_bucket}/config-snapshots/*"
        ]
      }
    ]
  })
}

# ─────────────────────────────────────────────
# EventBridge ターゲット実行ロール
# ─────────────────────────────────────────────

resource "aws_iam_role" "eventbridge_invoke" {
  name        = "csar-eventbridge-invoke-role"
  description = "Execution role for EventBridge Lambda targets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_invoke" {
  name = "csar-eventbridge-invoke-policy"
  role = aws_iam_role.eventbridge_invoke.id

  # Lambda ARNは後続フェーズ(Phase2)でLambda作成後に追加する
  # 現時点ではプレースホルダーARNを設定し、Phase2で上書き
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeLambdaRemediation"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        # 修復Lambda 4種: s3 / iam / ec2-sg / rds (Phase2で実際のARNに更新)
        Resource = [
          "arn:aws:lambda:${local.region}:${var.aws_account_id}:function:csar-remediation-s3",
          "arn:aws:lambda:${local.region}:${var.aws_account_id}:function:csar-remediation-iam",
          "arn:aws:lambda:${local.region}:${var.aws_account_id}:function:csar-remediation-ec2-sg",
          "arn:aws:lambda:${local.region}:${var.aws_account_id}:function:csar-remediation-rds"
        ]
      }
    ]
  })
}
