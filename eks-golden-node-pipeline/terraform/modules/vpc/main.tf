# VPC モジュール
# EKS 用 3層 VPC（public / private / intra）を構築する
# Karpenter ノードは private サブネットに配置する

locals {
  name = "${var.project}-${var.environment}"

  # サブネット CIDR を VPC CIDR から自動計算
  # 10.0.0.0/16 の場合:
  #   public:  10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24
  #   private: 10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24
  #   intra:   10.0.20.0/24, 10.0.21.0/24, 10.0.22.0/24
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  intra_subnets   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 20)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
  intra_subnets   = local.intra_subnets

  # NAT Gateway（dev環境はコスト削減のため1台）
  enable_nat_gateway     = true
  single_nat_gateway     = true # devのみ。本番は false にする
  one_nat_gateway_per_az = false

  # DNS 設定（EKS に必要）
  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC Flow Logs（セキュリティ監査用）
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  # EKS 用サブネットタグ（ALB / Karpenter が参照）
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1" # Internet-facing ALB 用
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"             # Internal ALB 用
    "karpenter.sh/discovery"          = "${local.name}" # Karpenter がサブネット検索に使用
  }

  tags = var.tags
}
