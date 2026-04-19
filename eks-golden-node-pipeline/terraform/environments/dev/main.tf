# dev 環境 Terraform エントリーポイント
# モジュールを呼び出して EKS + VPC を構築する

locals {
  project      = var.project
  environment  = var.environment
  cluster_name = "${var.project}-${var.environment}"

  # 共通タグ（CLAUDE.md のタグ戦略に従う）
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "infrastructure-team"
    CostCenter  = "platform"
  }
}

# VPC モジュール
module "vpc" {
  source = "../../modules/vpc"

  project     = local.project
  environment = local.environment
  vpc_cidr    = var.vpc_cidr
  tags        = local.common_tags
}

# EKS モジュール
module "eks" {
  source = "../../modules/eks"

  project            = local.project
  environment        = local.environment
  cluster_name       = local.cluster_name
  cluster_version    = var.eks_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  intra_subnet_ids   = module.vpc.intra_subnet_ids
  tags               = local.common_tags
}

# Karpenter モジュール
module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name                         = module.eks.cluster_name
  cluster_endpoint                     = module.eks.cluster_endpoint
  karpenter_version                    = var.karpenter_version
  karpenter_irsa_arn                   = module.eks.karpenter_irsa_arn
  karpenter_node_instance_profile_name = module.eks.karpenter_node_instance_profile_name
  karpenter_node_role_arn              = module.eks.karpenter_node_role_arn
  private_subnet_ids                   = module.vpc.private_subnet_ids

  # golden_ami_id を空にすると AMI 名フィルタで最新の Golden AMI を自動選択
  # CI/CD では packer-manifest.json から AMI ID を渡す
  golden_ami_id = var.golden_ami_id
  eks_version   = var.eks_version

  tags = local.common_tags
}
