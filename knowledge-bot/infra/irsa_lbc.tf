# AWS Load Balancer Controller 用の IRSA ロールとポリシーを定義する。
# 実運用では IAM ポリシー JSON を AWS 公式手順の最新状態に合わせて更新する前提。

data "aws_iam_policy_document" "lbc_assume" {
  count = var.enable_lbc ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  count = var.enable_lbc ? 1 : 0

  name               = "${local.name}-lbc"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume[0].json
  tags               = local.tags
}

# ポリシー本体は別ファイルに分離し、AWS 公式 JSON と差し替えやすくしている。
resource "aws_iam_policy" "lbc" {
  count = var.enable_lbc ? 1 : 0

  name   = "${local.name}-lbc-policy"
  policy = file("${path.module}/lbc_iam_policy.json")
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  count = var.enable_lbc ? 1 : 0

  role       = aws_iam_role.lbc[0].name
  policy_arn = aws_iam_policy.lbc[0].arn
}
