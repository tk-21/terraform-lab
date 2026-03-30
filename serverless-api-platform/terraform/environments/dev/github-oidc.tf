# terraform/environments/dev/github-oidc.tf
#
# GitHub Actions → AWS の OIDC フェデレーション設定。
#
# 長期的なIAMアクセスキーを発行・管理するリスクを排除するため、
# GitHub OIDC プロバイダを使用して一時的な認証情報を取得する。
#
# 信頼ポリシーは特定のリポジトリ・ブランチに限定することで、
# 意図しないリポジトリからの権限昇格を防ぐ。

locals {
  # GitHub OIDC プロバイダの設定値
  # thumbprint は GitHub の OIDC エンドポイントの TLS 証明書の
  # ルート CA フィンガープリント。定期的に確認・更新すること。
  github_oidc_thumbprint = "6938fd4d98bab03faadb97b34396831e3780aea1"

  # ここを自分の GitHub org/repo 名に変更すること
  github_org  = "your-github-org"
  github_repo = "serverless-api-platform"

  # CI/CD で書き込み操作（apply）を行うブランチを限定する
  # main ブランチへのマージのみ apply を許可する
  github_branch = "main"
}

# ============================================================
# GitHub OIDC プロバイダ
# ============================================================
# 同一アカウントで複数プロジェクトが OIDC を使用する場合、
# プロバイダは共有される。既存のプロバイダがある場合は
# data ソースで参照し、このリソースは削除すること。
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  # GitHub OIDC トークンの audience
  # GitHub Actions では "sts.amazonaws.com" が標準値
  client_id_list = ["sts.amazonaws.com"]

  # TLS 証明書の thumbprint（SHA-1 フィンガープリント）
  thumbprint_list = [local.github_oidc_thumbprint]
}

# ============================================================
# GitHub Actions 用 IAM ロール
# ============================================================
resource "aws_iam_role" "github_actions" {
  name = "${var.project}-${var.environment}-github-actions-role"

  # 信頼ポリシー：GitHub OIDC プロバイダからのみ AssumeRole を許可
  # sub クレームで org/repo/branch を限定し、
  # 意図しないリポジトリ・ブランチからの実行を防ぐ
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDCFederation"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # audience の検証
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            # main ブランチへの push のみ許可
            # PR のみの場合は "pull_request" を追加する
            "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/${local.github_repo}:ref:refs/heads/${local.github_branch}"
          }
        }
      }
    ]
  })

  description = "GitHub Actions OIDC role for ${local.github_org}/${local.github_repo} (${local.github_branch} branch)"
}

# ============================================================
# IAM ポリシー：Terraform / デプロイ操作に必要な権限
# ============================================================
# 最小権限の原則に基づき、このプロジェクトのリソースのみに限定する。
# * （ワイルドカード）リソース指定は CLAUDE.md の禁止事項であるため、
# 一部の操作（IAM ロール作成など list 系）を除き、
# リソース ARN を明示的に指定すること。
resource "aws_iam_role_policy" "github_actions" {
  name = "${var.project}-${var.environment}-github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ============================================================
      # Lambda
      # ============================================================
      {
        Sid    = "LambdaManage"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:DeleteFunction",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListFunctions",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:CreateEventSourceMapping",
          "lambda:DeleteEventSourceMapping",
          "lambda:GetEventSourceMapping",
          "lambda:PublishVersion",
          "lambda:CreateAlias",
          "lambda:UpdateAlias",
          "lambda:DeleteAlias",
          "lambda:TagResource",
          "lambda:UntagResource",
        ]
        Resource = "arn:aws:lambda:*:${var.account_id}:function:${var.project}-${var.environment}-*"
      },

      # ============================================================
      # API Gateway
      # ============================================================
      {
        Sid    = "ApiGatewayManage"
        Effect = "Allow"
        Action = [
          "apigateway:GET",
          "apigateway:POST",
          "apigateway:PUT",
          "apigateway:PATCH",
          "apigateway:DELETE",
        ]
        # API Gateway ARN は API ID が事前にわからないため * で指定
        # ただし tag 条件で制限することを推奨
        Resource = "arn:aws:apigateway:*::/*"
      },

      # ============================================================
      # DynamoDB
      # ============================================================
      {
        Sid    = "DynamoDBManage"
        Effect = "Allow"
        Action = [
          "dynamodb:CreateTable",
          "dynamodb:DeleteTable",
          "dynamodb:DescribeTable",
          "dynamodb:UpdateTable",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:UpdateTimeToLive",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:UpdateContinuousBackups",
          "dynamodb:ListTagsOfResource",
          "dynamodb:TagResource",
          "dynamodb:UntagResource",
          "dynamodb:DescribeStream",
        ]
        Resource = [
          "arn:aws:dynamodb:*:${var.account_id}:table/${var.project}-${var.environment}-*",
        ]
      },

      # ============================================================
      # Cognito
      # ============================================================
      {
        Sid    = "CognitoManage"
        Effect = "Allow"
        Action = [
          "cognito-idp:CreateUserPool",
          "cognito-idp:DeleteUserPool",
          "cognito-idp:DescribeUserPool",
          "cognito-idp:UpdateUserPool",
          "cognito-idp:CreateUserPoolClient",
          "cognito-idp:DeleteUserPoolClient",
          "cognito-idp:DescribeUserPoolClient",
          "cognito-idp:UpdateUserPoolClient",
          "cognito-idp:ListUserPools",
          "cognito-idp:ListUserPoolClients",
          "cognito-idp:AddCustomAttributes",
          "cognito-idp:TagResource",
          "cognito-idp:UntagResource",
        ]
        Resource = "*"
      },

      # ============================================================
      # S3（Lambda コード・監査ログ用）
      # ============================================================
      {
        Sid    = "S3Manage"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy",
          "s3:GetBucketVersioning",
          "s3:PutBucketVersioning",
          "s3:GetEncryptionConfiguration",
          "s3:PutEncryptionConfiguration",
          "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPublicAccessBlock",
          "s3:GetBucketTagging",
          "s3:PutBucketTagging",
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${var.project}-${var.environment}-*",
          "arn:aws:s3:::${var.project}-${var.environment}-*/*",
        ]
      },

      # ============================================================
      # Terraform ステートバケットへのアクセス
      # ============================================================
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::sap-tfstate-${var.account_id}",
          "arn:aws:s3:::sap-tfstate-${var.account_id}/*",
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
        Resource = "arn:aws:dynamodb:*:${var.account_id}:table/sap-tfstate-lock"
      },

      # ============================================================
      # CloudWatch
      # ============================================================
      {
        Sid    = "CloudWatchManage"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DescribeLogGroups",
          "logs:PutRetentionPolicy",
          "logs:DeleteRetentionPolicy",
          "logs:TagLogGroup",
          "logs:ListTagsLogGroup",
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:PutDashboard",
          "cloudwatch:DeleteDashboards",
          "cloudwatch:GetDashboard",
        ]
        Resource = "*"
      },

      # ============================================================
      # IAM（Lambda実行ロール管理）
      # ============================================================
      {
        Sid    = "IAMRoleManage"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${var.account_id}:role/${var.project}-${var.environment}-*"
      },
      {
        Sid    = "IAMOidcManage"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:TagOpenIDConnectProvider",
        ]
        Resource = "arn:aws:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"
      },
    ]
  })
}

# ============================================================
# Outputs
# ============================================================
output "github_actions_role_arn" {
  description = "GitHub Actions が AssumeRole するロールの ARN。GitHubリポジトリの Secrets に設定する。"
  value       = aws_iam_role.github_actions.arn
}
