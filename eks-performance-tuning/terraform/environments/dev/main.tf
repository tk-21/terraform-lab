locals {
  cluster_name = "ept-${var.environment}"
  common_tags = {
    Project     = "eks-performance-tuning"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
    Purpose     = "portfolio-performance"
  }
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "ept-dev-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  # Cost saving: single NAT gateway
  enable_nat_gateway = true
  single_nat_gateway = true

  # Required for AWS Load Balancer Controller
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  # Required for Karpenter node discovery and internal load balancers
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = local.cluster_name
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.cluster_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  private_subnet_ids = module.vpc.private_subnets
  aws_region         = var.aws_region
  cluster_version    = var.cluster_version
  common_tags        = local.common_tags
  karpenter_version  = var.karpenter_version
}

# -----------------------------------------------------------------------------
# Observability Stack (Prometheus / Grafana / X-Ray)
# -----------------------------------------------------------------------------
module "observability" {
  source = "../../modules/observability"

  environment          = var.environment
  aws_region           = var.aws_region
  cluster_name         = module.eks.cluster_name
  prometheus_retention = "15d"
  grafana_service_type = "ClusterIP"
}

# -----------------------------------------------------------------------------
# Kubernetes Namespaces
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "perf_tuning" {
  metadata {
    name = "perf-tuning"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      environment                    = var.environment
    }
  }

  depends_on = [module.eks]
}
