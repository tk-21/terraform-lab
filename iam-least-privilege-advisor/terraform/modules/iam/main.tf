data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------
# analyzer-trigger Lambda 実行ロール
# -----------------------------------------------------------------------
resource "aws_iam_role" "analyzer_trigger" {
  name = "${var.project_name}-analyzer-trigger"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_policy" "analyzer_trigger" {
  name        = "${var.project_name}-analyzer-trigger-policy"
  description = "analyzer-trigger Lambda に付与する最小権限ポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Access Analyzer: 一覧取得・スキャン実行・Findings 取得
      {
        Sid    = "AccessAnalyzerRead"
        Effect = "Allow"
        Action = [
          "access-analyzer:ListAnalyzers",
          "access-analyzer:StartResourceScan",
          "access-analyzer:ListFindings"
        ]
        Resource = "*"
      },
      # S3: 結果保存バケットへの書き込みのみ
      {
        Sid    = "S3PutResults"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${var.results_bucket_arn}/*"
      },
      # CloudWatch Logs
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-analyzer-trigger:*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "analyzer_trigger" {
  role       = aws_iam_role.analyzer_trigger.name
  policy_arn = aws_iam_policy.analyzer_trigger.arn
}

# policy-advisor Lambda から呼び出される権限を analyzer-trigger ロールに追加
# （Lambda → Lambda 非同期呼び出し用）
resource "aws_iam_policy" "analyzer_trigger_invoke_advisor" {
  name        = "${var.project_name}-analyzer-trigger-invoke-advisor-policy"
  description = "policy-advisor Lambda を非同期起動するための権限"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokePolicyAdvisor"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-policy-advisor"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "analyzer_trigger_invoke_advisor" {
  role       = aws_iam_role.analyzer_trigger.name
  policy_arn = aws_iam_policy.analyzer_trigger_invoke_advisor.arn
}

# -----------------------------------------------------------------------
# policy-advisor Lambda 実行ロール
# 注意: iam:PutPolicy / iam:PutUserPolicy / iam:PutRolePolicy /
#       iam:CreatePolicyVersion 等のポリシー変更系権限は一切付与しない
# -----------------------------------------------------------------------
resource "aws_iam_role" "policy_advisor" {
  name = "${var.project_name}-policy-advisor"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_policy" "policy_advisor" {
  name        = "${var.project_name}-policy-advisor-policy"
  description = "policy-advisor Lambda に付与する最小権限ポリシー（ポリシー変更系権限なし）"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3: 結果バケットからの読み取りのみ
      {
        Sid    = "S3GetResults"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${var.results_bucket_arn}/*"
      },
      # IAM: ポリシーの読み取りのみ（変更系は一切付与しない）
      # Resource を * にせず、ポリシー操作が最小限であることを明示
      {
        Sid    = "IAMReadOnly"
        Effect = "Allow"
        Action = [
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/*"
      },
      # Bedrock: 指定モデルの呼び出しのみ
      {
        Sid    = "BedrockInvokeModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}"
      },
      # Secrets Manager: GitHub Token と Chatwork Token の取得のみ
      {
        Sid    = "SecretsManagerGetSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          var.github_token_secret_arn,
          var.chatwork_secret_arn
        ]
      },
      # CloudWatch Logs
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-policy-advisor:*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "policy_advisor" {
  role       = aws_iam_role.policy_advisor.name
  policy_arn = aws_iam_policy.policy_advisor.arn
}
