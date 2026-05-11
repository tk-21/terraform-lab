# =============================================================
# eks-chaos-cell メインTerraform
# Phase 1: VPC + EKS のみ。Karpenter・FIS・観測は後フェーズ
# =============================================================

terraform {
  required_version = ">= 1.9"

  backend "s3" {
    bucket         = "eks-chaos-cell-tfstate-ACCOUNT_ID" # backend apply後に実際の値に変更
    key            = "eks-chaos-cell/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "eks-chaos-cell-tfstate-lock"
    encrypt        = true
  }

  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    tls  = { source = "hashicorp/tls", version = "~> 4.0" }
    helm = { source = "hashicorp/helm", version = "~> 2.0" }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

locals {
  cluster_name = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

module "vpc" {
  source       = "./modules/vpc"
  project_name = var.project_name
  cluster_name = local.cluster_name
  vpc_cidr     = var.vpc_cidr
  common_tags  = local.common_tags
}

module "eks" {
  source                   = "./modules/eks"
  cluster_name             = local.cluster_name
  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnet_ids
  private_subnet_ids_by_az = module.vpc.private_subnet_ids_by_az
  common_tags              = local.common_tags
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
  load_config_file = false
}

# =============================================================
# ALB Controller IRSA
# AWS Load Balancer ControllerがALBを作成・管理するためのIAMロール
# =============================================================
resource "aws_iam_role" "alb_controller" {
  name = "${local.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.eks.cluster_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(module.eks.cluster_oidc_issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

# ALB ControllerのIAMポリシー（AWSが提供する公式ポリシー）
resource "aws_iam_policy" "alb_controller" {
  name   = "${local.cluster_name}-alb-controller-policy"
  policy = file("${path.module}/policies/alb-controller-iam-policy.json")
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  policy_arn = aws_iam_policy.alb_controller.arn
  role       = aws_iam_role.alb_controller.name
}

module "karpenter" {
  source = "./modules/karpenter"

  cluster_name         = module.eks.cluster_name
  cluster_endpoint     = module.eks.cluster_endpoint
  aws_region           = var.aws_region
  aws_account_id       = var.aws_account_id
  project_name         = var.project_name
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer          = replace(module.eks.cluster_oidc_issuer, "https://", "")
  node_group_role_arn  = module.eks.node_group_role_arn
  node_group_role_name = module.eks.node_group_role_name
  common_tags          = local.common_tags
}

module "fis" {
  source         = "./modules/fis"
  cluster_name   = local.cluster_name
  aws_region     = var.aws_region
  aws_account_id = var.aws_account_id
  common_tags    = local.common_tags
}

module "observability" {
  source            = "./modules/observability"
  cluster_name      = local.cluster_name
  aws_region        = var.aws_region
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer       = replace(module.eks.cluster_oidc_issuer, "https://", "")
  common_tags       = local.common_tags
}
