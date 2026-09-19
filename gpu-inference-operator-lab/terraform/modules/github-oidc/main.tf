data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.prefix}-${var.env}"

  common_tags = merge(var.tags, {
    ManagedBy   = "terraform"
    Project     = var.prefix
    Environment = var.env
  })
}

# GitHub ActionsのOIDCプロバイダー
# token.actions.githubusercontent.com が発行するJWTをAWSが直接検証する
# thumbprintはGitHub OIDCエンドポイントのTLS証明書のSHA1フィンガープリント
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.common_tags
}

# GitHub Actions用IAMロール
# ワイルドカードは使わず、指定したリポジトリのmainブランチ・タグからのみAssumeRoleを許可する
resource "aws_iam_role" "github_actions" {
  # 64文字制限: "giop-dev-github-actions-role" = 29文字 (余裕あり)
  name = "${local.name_prefix}-github-actions-role"

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
            # aud: GitHub Actions公式のSTSエンドポイントのみ許可する
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # sub: 指定リポジトリのmainブランチとvタグのみに絞る
            # ブランチ指定をしないとforkからもAssumeRoleできてしまうため必須
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
              "repo:${var.github_org}/${var.github_repo}:ref:refs/tags/v*",
            ]
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# ECRへのpush権限
# イメージのpush・pullに必要な最小限のアクションのみを許可する
resource "aws_iam_role_policy" "ecr_push" {
  name = "${local.name_prefix}-ecr-push-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken はリソース指定できないため * になる
        # ただし docker login 相当の操作のみで、実際のpush権限はリポジトリARNで制限する
        Sid    = "ECRGetToken"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # 指定したECRリポジトリへのイメージpushのみを許可する
        # ListImages/DescribeImages はCI上でのイメージ重複確認に使う
        Sid    = "ECRPushToRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:ListImages",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_name}"
      },
    ]
  })
}
