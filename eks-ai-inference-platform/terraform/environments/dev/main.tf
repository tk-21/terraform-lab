terraform {
  required_version = ">= 1.9"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
  }
  backend "s3" {
    # デプロイ前にS3バケットを手動作成すること
    bucket = "tfstate-eks-ai-inference-platform"
    key    = "dev/terraform.tfstate"
    region = "ap-northeast-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# EKSクラスター作成後にhelmとkubernetesプロバイダーが初期化されるため
# exec方式でトークンを動的取得する
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

module "vpc" {
  source      = "../../modules/vpc"
  project     = var.project
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
}

module "eks" {
  source             = "../../modules/eks"
  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  cluster_version    = var.cluster_version
  node_instance_type = var.node_instance_type
  # S3 Gateway Endpoint ID: vLLMモデルキャッシュバケットポリシーでVPC外アクセスを拒否するため必要
  s3_vpc_endpoint_id = module.vpc.s3_vpc_endpoint_id
  # VPC CIDR: EKS APIエンドポイントのSGインバウンドルールに使用する
  vpc_cidr = var.vpc_cidr
}

module "karpenter" {
  source                        = "../../modules/karpenter"
  project                       = var.project
  environment                   = var.environment
  cluster_name                  = module.eks.cluster_name
  cluster_endpoint              = module.eks.cluster_endpoint
  karpenter_controller_irsa_arn = module.eks.karpenter_controller_irsa_arn
  karpenter_queue_arn           = module.eks.karpenter_queue_arn
  karpenter_queue_url           = module.eks.karpenter_queue_url
}

module "observability" {
  source      = "../../modules/observability"
  project     = var.project
  environment = var.environment
  # EKS OIDCプロバイダー情報: OTEL Collector IRSAの信頼ポリシー構築に使用する
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
}

module "gateway" {
  source      = "../../modules/gateway"
  project     = var.project
  environment = var.environment
  # AI Gateway IRSA の信頼ポリシー構築に使用する
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
}

module "keda" {
  source      = "../../modules/keda"
  project     = var.project
  environment = var.environment
  # KEDA IRSA の信頼ポリシー構築に使用する
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  # KEDAがAMPにクエリするためのワークスペースARN
  amp_workspace_arn = module.observability.amp_workspace_arn
}
