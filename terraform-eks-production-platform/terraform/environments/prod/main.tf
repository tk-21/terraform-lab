################################################################################
# prod環境 - メイン設定
#
# このファイルでプロバイダーを定義し、各モジュールを呼び出す。
# モジュール間の依存関係はoutput/variableで明示的に管理する。
################################################################################

################################################################################
# Terraformとプロバイダーのバージョン設定
#
# プロバイダーバージョンを ~> 記法で固定する理由：
# メジャーバージョンアップは破壊的変更を含む可能性があるため、
# パッチ・マイナーバージョンの自動更新は許容しつつメジャーは固定する。
################################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Kubernetes Providerを使う理由：
    # aws-auth ConfigMap等をTerraformで管理するために必要。
    # kubectlコマンドに依存せずにKubernetesリソースを管理できる。
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }

    # Helm Providerを使う理由：
    # ArgoCD・Karpenter・LBCのデプロイをTerraformのライフサイクルで管理できる。
    # helm installを手動実行する場合のドリフトをterraform planで検知できる。
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }

    # TLS Providerを使う理由：
    # EKS OIDC ProviderのサムプリントをTerraform内で動的取得するために使用。
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    # ランダム値生成（ArgoCDパスワード等）
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }

    # htpasswdプロバイダー（ArgoCDのbcryptパスワード生成）
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "~> 1.0"
    }
  }
}

################################################################################
# プロバイダー設定
################################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Kubernetes ProviderはEKSクラスター作成後に設定を取得する必要がある。
# data sourceを使ってクラスター作成後に動的に設定される。
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # AWS CLI経由でEKSの認証トークンを取得する
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

################################################################################
# ローカル変数
################################################################################

locals {
  # 共通タグ：すべてのリソースに付与する
  # Ownerタグで誰が管理しているかを明確にすることで
  # 不要リソースの特定と削除が容易になる
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  }
}

################################################################################
# VPCモジュール
################################################################################

module "vpc" {
  source = "../../modules/vpc"

  project_name = var.project_name
  environment  = var.environment
  common_tags  = local.common_tags

  vpc_cidr              = "10.0.0.0/16"
  availability_zones    = ["ap-northeast-1a", "ap-northeast-1c"]
  public_subnet_cidrs   = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs  = ["10.0.10.0/23", "10.0.12.0/23"]
  isolated_subnet_cidrs = ["10.0.20.0/24", "10.0.21.0/24"]

  # 本番環境: 高可用性のためAZごとにNAT Gatewayを配置（コスト: 約$65/月）
  # 検証環境: falseにして1つのNAT Gatewayに削減（コスト: 約$32/月）
  enable_nat_gateway_per_az = true
}

################################################################################
# EKSモジュール
################################################################################

module "eks" {
  source = "../../modules/eks"

  project_name = var.project_name
  environment  = var.environment
  common_tags  = local.common_tags

  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  vpc_cidr_block      = module.vpc.vpc_cidr_block

  cluster_version     = var.eks_cluster_version
  public_access_cidrs = var.eks_public_access_cidrs

  node_group_instance_types = var.node_group_instance_types
  node_group_desired_size   = 2
  node_group_min_size       = 1
  node_group_max_size       = 3
  node_group_disk_size      = 50

  depends_on = [module.vpc]
}

################################################################################
# Addonsモジュール
################################################################################

module "addons" {
  source = "../../modules/addons"

  project_name = var.project_name
  environment  = var.environment
  common_tags  = local.common_tags
  aws_region   = var.aws_region

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  vpc_id                             = module.vpc.vpc_id

  lbc_irsa_role_arn                    = module.eks.lbc_irsa_role_arn
  karpenter_irsa_role_arn              = module.eks.karpenter_irsa_role_arn
  karpenter_sqs_queue_name             = module.eks.karpenter_sqs_queue_name
  karpenter_node_instance_profile_name = module.eks.karpenter_node_instance_profile_name
  argocd_irsa_role_arn                 = module.eks.argocd_irsa_role_arn

  karpenter_version = var.karpenter_version
  argocd_version    = var.argocd_version

  depends_on = [module.eks]
}

################################################################################
# Observabilityモジュール
################################################################################

module "observability" {
  source = "../../modules/observability"

  project_name = var.project_name
  environment  = var.environment
  common_tags  = local.common_tags
  aws_region   = var.aws_region

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  grafana_admin_user     = var.grafana_admin_user
  grafana_admin_user_ids = var.grafana_admin_user_ids

  depends_on = [module.eks]
}
