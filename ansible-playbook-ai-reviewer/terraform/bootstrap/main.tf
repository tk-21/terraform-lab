# ============================================================
# bootstrap/
# GitHub Actions OIDC 認証用 IAM リソース
#
# 用途:
#   モノレポ直下のワークフロー ansible-ai-reviewer-deploy.yml が
#   AWS に OIDC で接続するための IAM ロールを作成する。
#   アクセスキーは一切使用しない。
#
# なぜ environments/dev と分けるのか:
#   CI が引き受けるロールを、CI が plan する同じスタックで管理すると
#   「ロールが無いと plan できない」という鶏卵問題になるため、
#   独立した state（key: .../bootstrap/terraform.tfstate）で管理する。
#
# 適用方法（初回のみ、ユーザー自身が手元で実行）:
#   cd terraform/bootstrap
#   terraform init
#   terraform plan  -var="github_owner=<GitHubユーザー/組織名>"
#   terraform apply -var="github_owner=<GitHubユーザー/組織名>"
#
# 適用後:
#   terraform output role_arn の値を GitHub の Secrets > AWS_ROLE_ARN に登録する
# ============================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # thumbprint_list が省略可能になった 5.81 以降を要求する
      version = "~> 5.81"
    }
  }

  backend "s3" {
    bucket  = "terraform-state-ansible-ai-reviewer"
    key     = "ansible-playbook-ai-reviewer/bootstrap/terraform.tfstate"
    region  = "ap-northeast-1"
    encrypt = true
    # S3 ネイティブロック (Terraform 1.10+)
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  oidc_url = "token.actions.githubusercontent.com"

  # 作成した場合は新規リソース、しない場合は既存プロバイダの ARN を使う
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  common_tags = {
    Project     = var.project_name
    Environment = "shared"
    ManagedBy   = "terraform"
    Owner       = "infra-team"
    CostCenter  = "portfolio"
  }
}

# ============================================================
# GitHub Actions OIDC Provider
# ============================================================

# GitHub の OIDC プロバイダは AWS アカウントに 1 つしか登録できない。
# モノレポの他プロジェクトが作成済みの場合は参照だけにする（create_oidc_provider = false）。
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://${local.oidc_url}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_url}"
  client_id_list = ["sts.amazonaws.com"]

  tags = local.common_tags
}

# ============================================================
# IAM ロール: GitHub Actions 用
# ============================================================

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # main への push / 手動実行 と、PR（plan 用）だけを許可する。
    # repo:<owner>/<repo>:* は fork 由来の実行などまで許すため使わない。
    condition {
      test     = "StringLike"
      variable = "${local.oidc_url}:sub"
      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_owner}/${var.github_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  # IAM ロール名は 64 文字以内
  name               = var.role_name
  description        = "GitHub Actions OIDC role for ${var.project_name} (plan / Lambda deploy)"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = local.common_tags
}

# ============================================================
# 権限: terraform plan（読み取り）と Lambda デプロイのみ
# ============================================================

# terraform plan はリソースの現状を読み取るため ReadOnlyAccess を付与する。
# ワークフローは apply を実行しないので、書き込み権限は下の個別ポリシーに限定する。
resource "aws_iam_role_policy_attachment" "read_only" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "deploy" {
  # Lambda コードの更新とバージョン発行（対象関数のみ）
  statement {
    sid    = "LambdaDeploy"
    effect = "Allow"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:PublishVersion",
    ]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.function_name}",
    ]
  }

  # Terraform state の読み書き（use_lockfile のロックファイルも同じバケットに書かれる）
  statement {
    sid    = "StateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}/${var.project_name}/*",
    ]
  }

  statement {
    sid       = "StateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.role_name}-deploy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.deploy.json
}
