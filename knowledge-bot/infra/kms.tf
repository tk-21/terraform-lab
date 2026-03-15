data "aws_iam_policy_document" "kms_knowledge" {
  # 1) 管理者（アカウントroot）にフル権限
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

  # 2) ★追加：Bedrock KB ロールに復号権限（S3上の暗号化オブジェクト読取りに必要）
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

    # 任意：S3経由の復号に限定したい場合（より安全）
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
