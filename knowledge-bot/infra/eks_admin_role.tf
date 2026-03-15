# あなたの SSO ロール（IAM role ARN）を指定
# ※ "sts::...:assumed-role/..." ではなく "iam::...:role/..." にする
variable "sso_admin_role_arn" {
  type        = string
  description = "SSO AdministratorAccess role ARN in IAM format (arn:aws:iam::ACCOUNT:role/AWSReservedSSO_...)"
  default     = ""
}

locals {
  # IAM role ARN の末尾（RoleName）を取り出して実ARNを再解決する。
  # SSOロールは path 付きARNのため、単純なARN直指定だと不一致になりやすい。
  sso_admin_role_name = var.sso_admin_role_arn != "" ? element(split("/", var.sso_admin_role_arn), length(split("/", var.sso_admin_role_arn)) - 1) : ""
}

data "aws_iam_role" "sso_admin" {
  count = local.sso_admin_role_name != "" ? 1 : 0
  name  = local.sso_admin_role_name
}

resource "aws_iam_role" "eks_admin" {
  name = "${local.name}-eks-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::999828867039:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

# EKS Access Entry を “固定の IAM Role” に付与する
resource "aws_eks_access_entry" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.eks_admin.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.eks_admin.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# 現在の運用者（SSOロール）にも直接クラスタ管理者アクセスを付与
resource "aws_eks_access_entry" "sso_admin" {
  count = local.sso_admin_role_name != "" ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_role.sso_admin[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "sso_admin" {
  count = local.sso_admin_role_name != "" ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_role.sso_admin[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
