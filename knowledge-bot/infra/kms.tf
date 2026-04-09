# ナレッジ用 S3 バケット暗号化に使う KMS キーと、その利用ポリシーを定義する。
data "aws_iam_policy_document" "kms_knowledge" {
  # アカウント管理者は引き続きキーをフル管理できるようにする。
  statement {
    sid     = "EnableRootPermissions"
    effect  = "Allow"
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    resources = ["*"]
  }

  # Bedrock KB ロールには、S3 上の暗号化済みドキュメントを読むための権限だけを渡す。
  statement {
    sid    = "AllowKBRoleDecrypt"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.kb.arn]
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]
    resources = ["*"]

    # S3 経由の利用に限定し、他サービスからの復号を防ぐ。
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "knowledge" {
  description             = "${local.name} knowledge bucket key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_knowledge.json
  tags                    = local.tags
}

resource "aws_kms_alias" "knowledge" {
  name          = "alias/${local.name}-knowledge"
  target_key_id = aws_kms_key.knowledge.key_id
}
