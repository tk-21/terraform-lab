# =============================================================================
# GitHub Actions OIDC 連携
#
# 目的:
#   GitHub Actions から AWS を操作するための OIDC 認証基盤。
#   アクセスキーを一切使わず、一時クレデンシャルで安全に認証する。
#
# 初回セットアップ手順:
#   1. ローカルで AWS CLI の認証情報を設定する（bootstrap 用）
#   2. terraform init && terraform apply -target=aws_iam_openid_connect_provider.github
#      を実行して OIDC プロバイダーを作成する
#   3. 出力された IAM ロール ARN を GitHub Secrets の TF_ROLE_ARN に登録する
#   4. 以降の terraform apply は GitHub Actions が OIDC で自動実行する
#
# 注意:
#   aws_iam_openid_connect_provider は AWS アカウント内に 1 つだけ作成される。
#   すでに存在する場合は terraform import で取り込むこと:
#     terraform import aws_iam_openid_connect_provider.github \
#       arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
# =============================================================================

data "aws_caller_identity" "oidc" {}

# =============================================================================
# GitHub Actions OIDC プロバイダー
# AWS アカウントに 1 つだけ作成する（既存の場合は import）
# =============================================================================
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # GitHub Actions の JWT を受け取る対象者（sts.amazonaws.com 固定）
  client_id_list = ["sts.amazonaws.com"]

  # GitHub の OIDC エンドポイント TLS 証明書のサムプリント
  # 参考: https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# =============================================================================
# GitHub Actions 用 IAM ロール
# 特定リポジトリの GitHub Actions のみが assume できるよう制限する
# =============================================================================
resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # aud は必ず sts.amazonaws.com にする（aws-actions/configure-aws-credentials の仕様）
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # 特定リポジトリからのみ assume を許可（:* でブランチ/タグ/PR を全許可）
            # 本番では ":ref:refs/heads/main" に絞ることを推奨
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
          }
        }
      }
    ]
  })

  description = "GitHub Actions (${var.github_repository}) 用の OIDC ロール"
}

# =============================================================================
# GitHub Actions 用 IAM ポリシー
#
# スコープ: このプロジェクトが管理するリソースに限定する
#
# 注意（学習用途での妥協点）:
#   IAM・API Gateway・X-Ray は Resource="*" が必要な API が存在するため
#   これらのサービスは広めの権限になっている。
#   本番環境では Permissions Boundary を追加して権限の上限を設けることを推奨。
# =============================================================================
resource "aws_iam_role_policy" "github_actions_terraform" {
  name = "terraform-deploy-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # -----------------------------------------------------------------------
      # Terraform State バックエンド（S3 + DynamoDB）
      # -----------------------------------------------------------------------
      {
        Sid    = "TerraformStateS3"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = [
          "arn:aws:s3:::tfstate-${var.project_name}",
          "arn:aws:s3:::tfstate-${var.project_name}/*",
        ]
      },
      {
        Sid    = "TerraformStateLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:table/tfstate-lock-${var.project_name}"
      },

      # -----------------------------------------------------------------------
      # Lambda
      # -----------------------------------------------------------------------
      {
        Sid    = "Lambda"
        Effect = "Allow"
        Action = ["lambda:*"]
        Resource = [
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:function:${var.project_name}-*",
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:layer:*",
        ]
      },

      # -----------------------------------------------------------------------
      # IAM（ロール・ポリシー・OIDC プロバイダーの管理）
      # -----------------------------------------------------------------------
      {
        Sid    = "IAMRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:PassRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.oidc.account_id}:role/${var.project_name}-*"
      },
      {
        Sid    = "IAMOIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviders",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:AddClientIDToOpenIDConnectProvider",
          "iam:RemoveClientIDFromOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
        ]
        Resource = "*"
      },

      # -----------------------------------------------------------------------
      # DynamoDB（プロジェクト管理リソース）
      # -----------------------------------------------------------------------
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = ["dynamodb:*"]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:table/${var.project_name}-*",
        ]
      },

      # -----------------------------------------------------------------------
      # S3（プロジェクト管理バケット）
      # -----------------------------------------------------------------------
      {
        Sid    = "S3Managed"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*",
          "arn:aws:s3:::${var.project_name}-*/*",
        ]
      },

      # -----------------------------------------------------------------------
      # API Gateway
      # -----------------------------------------------------------------------
      {
        Sid      = "APIGateway"
        Effect   = "Allow"
        Action   = ["apigateway:*"]
        Resource = "arn:aws:apigateway:${var.aws_region}::/*"
      },

      # -----------------------------------------------------------------------
      # Step Functions
      # -----------------------------------------------------------------------
      {
        Sid    = "StepFunctions"
        Effect = "Allow"
        Action = ["states:*"]
        Resource = [
          "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:stateMachine:${var.project_name}-*",
          "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:execution:${var.project_name}-*:*",
        ]
      },

      # -----------------------------------------------------------------------
      # CloudWatch Logs
      # -----------------------------------------------------------------------
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:*"]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:log-group:/aws/lambda/${var.project_name}-*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:log-group:/aws/api-gateway/${var.project_name}-*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:log-group:/aws/states/${var.project_name}-*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:log-group:*:log-stream:*",
        ]
      },
      {
        # API Gateway アカウント設定・CloudWatch Logs 配信設定
        Sid      = "CloudWatchLogsDelivery"
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:GetLogDelivery",
                    "logs:UpdateLogDelivery", "logs:DeleteLogDelivery",
                    "logs:ListLogDeliveries", "logs:PutResourcePolicy",
                    "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      },

      # -----------------------------------------------------------------------
      # SSM Parameter Store（Chatwork トークン）
      # -----------------------------------------------------------------------
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:DeleteParameter",
          "ssm:DescribeParameters",
          "ssm:ListTagsForResource",
          "ssm:AddTagsToResource",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.oidc.account_id}:parameter/${var.project_name}/*"
      },

      # -----------------------------------------------------------------------
      # X-Ray
      # -----------------------------------------------------------------------
      {
        Sid      = "XRay"
        Effect   = "Allow"
        Action   = ["xray:*"]
        Resource = "*"
      },
    ]
  })
}

# =============================================================================
# 出力: GitHub Secrets に登録する値
# =============================================================================
output "github_actions_role_arn" {
  description = <<-EOT
    GitHub Secrets の TF_ROLE_ARN に登録する IAM ロール ARN。
    リポジトリ Settings → Secrets and variables → Actions → New repository secret
  EOT
  value = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "GitHub Actions OIDC プロバイダー ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}
