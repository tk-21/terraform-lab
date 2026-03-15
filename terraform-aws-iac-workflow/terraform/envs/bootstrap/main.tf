locals {
  repo_full = "${var.github_owner}/${var.github_repo}"

  # ✅ リポジトリ配下の全てのrefを許可（ブランチ/タグ/PRでも通る）
  allowed_subs = [
    "repo:${local.repo_full}:*"
  ]
}

# 1) GitHub Actions 用 OIDC Provider（AWSアカウントに1回作れば基本OK）
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # GitHub Actions OIDCの一般的なthumbprint
  # （この値は定番。必要になったら運用で更新）
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
}

# 2) GitHub Actions が Assume できる IAM Role の Trust Policy
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    # aud は sts.amazonaws.com 固定
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # sub で「どのRepo/どのbranchか」を縛る
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.allowed_subs
    }
  }
}

resource "aws_iam_role" "github_actions_terraform" {
  name               = "github-actions-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

# 学習用：まずは Admin 付与（動かすの優先）
resource "aws_iam_role_policy_attachment" "admin" {
  count      = var.attach_admin_policy ? 1 : 0
  role       = aws_iam_role.github_actions_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
