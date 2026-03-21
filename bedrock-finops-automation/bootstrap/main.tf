# ============================================================
# bootstrap/
# GitHub Actions OIDC 認証用 IAM リソース
#
# 用途:
#   terraform plan / apply を実行する GitHub Actions ワークフローに
#   AWS 認証を付与するための IAM ロールを作成する。
#   アクセスキーは一切使用しない（OIDC のみ）。
#
# 適用方法（初回のみ手動で実行）:
#   cd bootstrap/
#   terraform init
#   terraform apply -var="github_owner=YOUR_GITHUB_USERNAME"
#
# 適用後:
#   terraform output github_actions_role_arn の値を
#   GitHub リポジトリの Secrets > AWS_ROLE_ARN に登録する
# ============================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

# ============================================================
# GitHub Actions OIDC Provider
# ============================================================

# GitHub Actions の OIDC エンドポイントを AWS に登録する
# 同一 AWS アカウントで既に登録済みの場合は data source で参照する
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  # GitHub Actions の OIDC トークンを受け取る対象（audience）
  client_id_list = ["sts.amazonaws.com"]

  # GitHub OIDC Provider のサーバー証明書 thumbprint
  # 参考: https://github.blog/changelog/2022-01-13-github-actions-update-on-oidc-based-deployments-to-aws/
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd", # 2023年追加の中間 CA
  ]
}

# ============================================================
# IAM Role - GitHub Actions 実行ロール
# ============================================================

resource "aws_iam_role" "github_actions" {
  name        = "github-actions-${var.project_name}"
  description = "GitHub Actions OIDC role for ${var.project_name} Terraform CI/CD"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # audience 固定: AWS STS
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # 対象リポジトリのすべてのブランチ・PR を許可
            # plan（PR）と apply（main push）の両方に対応するため "*" を使用
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_owner}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
    Purpose = "github-actions-cicd"
  }
}

# ============================================================
# IAM Policy - Terraform 実行権限
# ============================================================

# AdministratorAccess をアタッチ
# 理由: Terraform は IAM ロール・ポリシー等を作成するため、
#       PowerUserAccess では不足する（IAM 操作が必要）
# セキュリティ考慮:
#   - ロールは上記 Condition でリポジトリ単位にスコープ制限済み
#   - main ブランチの保護ルール + PR レビュー必須で apply を制御する
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
