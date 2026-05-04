# ─────────────────────────────────────────────
# S3 ポリシー: provider-aws-s3 が使うアクションのみ
# ─────────────────────────────────────────────
resource "aws_iam_policy" "crossplane_s3" {
  name        = "${local.name_prefix}-crossplane-s3"
  path        = "/crossplane/"
  description = "Crossplane provider-aws-s3 の最小権限ポリシー"
  tags        = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # バケット一覧取得はリソーススコープが * に限定される AWS 仕様
        Sid      = "S3ListAllBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets"]
        Resource = "*"
      },
      {
        # Composition で作成されるバケット名は "idp-*" に限定されるため ARN を絞る
        Sid    = "S3ManageBuckets"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketTagging",
          "s3:PutBucketTagging",
          "s3:DeleteBucketTagging",
          "s3:GetBucketAcl",
          "s3:PutBucketAcl",
          "s3:GetBucketVersioning",
          "s3:PutBucketVersioning",
          "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPublicAccessBlock",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${var.bucket_prefix}-*",
        ]
      },
    ]
  })
}

# ─────────────────────────────────────────────
# IAM ポリシー: provider-aws-iam が使うアクションのみ
# /crossplane/ パス配下のリソースに限定する
# ─────────────────────────────────────────────
resource "aws_iam_policy" "crossplane_iam" {
  name        = "${local.name_prefix}-crossplane-iam"
  path        = "/crossplane/"
  description = "Crossplane provider-aws-iam の最小権限ポリシー"
  tags        = local.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IAMRoleManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
        ]
        # Crossplane が作成するロールは /crossplane/ パス配下に限定
        Resource = [
          "arn:aws:iam::*:role/crossplane/*",
        ]
      },
      {
        Sid    = "IAMPolicyManagement"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:ListPolicyVersions",
          "iam:TagPolicy",
          "iam:UntagPolicy",
        ]
        Resource = [
          "arn:aws:iam::*:policy/crossplane/*",
        ]
      },
      {
        # PassRole は /crossplane/ 配下のロールに限定
        Sid      = "IAMPassRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = ["arn:aws:iam::*:role/crossplane/*"]
      },
    ]
  })
}
