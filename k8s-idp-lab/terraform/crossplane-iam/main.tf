# Crossplane が AWS を操作するための IAM ユーザー
# kind クラスターは OIDC を使えないため、アクセスキー方式を採用する
resource "aws_iam_user" "crossplane" {
  name = "${local.name_prefix}-crossplane"
  path = "/crossplane/"
  tags = local.common_tags
}

resource "aws_iam_user_policy_attachment" "s3" {
  user       = aws_iam_user.crossplane.name
  policy_arn = aws_iam_policy.crossplane_s3.arn
}

resource "aws_iam_user_policy_attachment" "iam" {
  user       = aws_iam_user.crossplane.name
  policy_arn = aws_iam_policy.crossplane_iam.arn
}

# アクセスキーは terraform output で取得後、K8s Secret に登録する
resource "aws_iam_access_key" "crossplane" {
  user = aws_iam_user.crossplane.name
}
