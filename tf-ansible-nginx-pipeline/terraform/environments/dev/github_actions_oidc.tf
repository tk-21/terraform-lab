# =============================================================================
# GitHub Actions OIDC認証設定
# 設計思想: 静的アクセスキーを一切使わない
# OIDCにより「このリポジトリのこのブランチからのみ」AWS操作を許可する
# =============================================================================

data "aws_caller_identity" "current" {}

# GitHub ActionsのOIDCプロバイダー（AWSアカウントに1つだけ作成）
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHubのOIDCサービスの証明書フィンガープリント
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# GitHub Actions実行ロール
resource "aws_iam_role" "github_actions" {
  name = "handson-dev-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          # セキュリティ設計: 特定リポジトリのmainブランチからのみ許可
          "token.actions.githubusercontent.com:sub" = "repo:tk-21/tf-ansible-nginx-pipeline:ref:refs/heads/main"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Terraform操作用ポリシー（最小権限）
resource "aws_iam_role_policy" "github_actions_terraform" {
  name = "handson-dev-github-actions-terraform-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::handson-dev-tfstate",
          "arn:aws:s3:::handson-dev-tfstate/*"
        ]
      },
      {
        Sid    = "TerraformLockAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:ap-northeast-1:*:table/handson-dev-tflock"
      },
      {
        Sid    = "EC2ReadOnly"
        Effect = "Allow"
        Action = ["ec2:Describe*"]
        Resource = "*"
      },
      {
        Sid    = "SSMReadForAnsible"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter", "ssm:GetParameters",
          "ssm:GetParametersByPath", "ssm:DescribeInstanceInformation",
          "ssm:StartSession", "ssm:TerminateSession",
          "ssm:SendCommand", "ssm:ListCommandInvocations"
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  description = "GitHub ActionsワークフローのAWS_ROLE_ARNに設定する"
  value       = aws_iam_role.github_actions.arn
}
