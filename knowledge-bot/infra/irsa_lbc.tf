# AWS公式推奨のポリシーJSONはバージョンで更新されることがあるので
# 実運用は “公式手順の最新” を参照するのが安全です :contentReference[oaicite:5]{index=5}
# ここでは「最低限動く」ために、install手順に沿って作る前提で割り切ります。

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

# ポリシーはAWS公式ドキュメント／公式手順のJSONを貼り付け運用が鉄板（更新追従しやすい）
# 例：re:Postや公式ガイドに「IAM policyを作れ」と明記 :contentReference[oaicite:6]{index=6}
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
