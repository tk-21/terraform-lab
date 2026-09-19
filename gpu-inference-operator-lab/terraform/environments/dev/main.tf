locals {
  prefix = "giop"
  env    = "dev"
}

module "vpc" {
  source = "../../modules/vpc"

  prefix               = local.prefix
  env                  = local.env
  vpc_cidr             = "10.0.0.0/16"
  private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  azs                  = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
}

module "eks" {
  source = "../../modules/eks"

  prefix             = local.prefix
  env                = local.env
  cluster_version    = "1.30"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # Graviton2(arm64)でシステムコンポーネントを動かす
  system_node_instance_types = ["t4g.medium"]
  system_node_desired        = 2
  system_node_min            = 2
  system_node_max            = 4
}

module "karpenter" {
  source = "../../modules/karpenter"

  prefix            = local.prefix
  env               = local.env
  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  node_role_arn     = module.eks.node_role_arn
  karpenter_version = "0.37.0"
  gpu_nodepool_name = "karpenter-gpu-g5g"
}

module "iam" {
  source = "../../modules/iam"

  prefix            = local.prefix
  env               = local.env
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.cluster_oidc_issuer
  bedrock_model_ids = [
    "anthropic.claude-3-haiku-20240307-v1:0",
    "anthropic.claude-3-sonnet-20240229-v1:0",
  ]
}

# Chatwork APIトークンのSSM Parameter Store登録
# 値は空で作成し、コンソール or `aws ssm put-parameter --overwrite`で手動設定する
module "github_oidc" {
  source = "../../modules/github-oidc"

  prefix              = local.prefix
  env                 = local.env
  github_org          = "takuya"
  github_repo         = "gpu-inference-operator-lab"
  ecr_repository_name = "gpu-inference-operator"
}

resource "aws_ssm_parameter" "chatwork_token" {
  name        = "/gpu-inference-operator-lab/chatwork-token"
  type        = "SecureString"
  value       = "PLACEHOLDER_SET_MANUALLY"
  description = "Chatwork APIトークン (OperatorのChatwork通知に使用)"

  lifecycle {
    # 値の更新はコンソール/CLIで行うため、Terraform管理外にする
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "chatwork_room_id" {
  name        = "/gpu-inference-operator-lab/chatwork-room-id"
  type        = "String"
  value       = "PLACEHOLDER_SET_MANUALLY"
  description = "Chatwork 通知先ルームID"

  lifecycle {
    ignore_changes = [value]
  }
}
