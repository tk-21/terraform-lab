# =============================================================================
# dev環境 Terraform設定 - EKS Chaos Postmortem Generator
# VPCモジュールとEKSモジュールを呼び出してdev環境を構築する
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  # S3バックエンドでTerraformステートを管理
  # 実行例: terraform init -backend-config="bucket=eks-chaos-postmortem-tfstate"
  backend "s3" {
    bucket = "eks-chaos-postmortem-tfstate"
    key    = "eks-chaos-postmortem/dev/terraform.tfstate"
    region = "ap-northeast-1"
  }
}

provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = {
      Project    = "eks-chaos-postmortem-generator"
      ManagedBy  = "terraform"
      Owner      = "takuya"
      CostCenter = "portfolio"
    }
  }
}

# Kubernetes provider（EKS クラスター管理用）
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# EKS クラスター認証トークンの取得
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

# ============================================================
# ローカル変数: 環境設定の一元管理
# ============================================================

locals {
  project     = "eks-chaos-postmortem-generator"
  environment = "dev"
  # EKSクラスター名の命名規則: {project}-{environment}
  cluster_name = "eks-chaos-postmortem-dev"

  # 全リソースに付与する共通タグ（5種必須）
  tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
    CostCenter  = "portfolio"
  }
}

# ============================================================
# VPCモジュール: 3層ネットワーク基盤の構築
# ============================================================

module "vpc" {
  source = "../../modules/vpc"

  project      = local.project
  environment  = local.environment
  cluster_name = local.cluster_name
  tags         = local.tags
}

# ============================================================
# EKSモジュール: Kubernetesクラスターの構築
# ============================================================

module "eks" {
  source = "../../modules/eks"

  project            = local.project
  environment        = local.environment
  cluster_name       = local.cluster_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  aws_account_id     = var.aws_account_id
  tags               = local.tags
}

# ============================================================
# FISモジュール: カオスエンジニアリング実験テンプレート
# 4種類の実験（pod-kill / node-termination / network-latency / cpu-stress）を管理する
# ============================================================

module "fis" {
  source = "../../modules/fis"

  project      = local.project
  environment  = local.environment
  region       = "ap-northeast-1"
  cluster_name = module.eks.cluster_name
  cluster_arn  = module.eks.cluster_arn
  tags         = local.tags
}

# ============================================================
# S3モジュール: ポストモーテムHTMLレポート保存バケット
# report-formatter LambdaがHTMLレポートを保存し、presigned URLを発行する。
# ============================================================

module "s3" {
  source = "../../modules/s3"

  project        = local.project
  environment    = local.environment
  aws_account_id = var.aws_account_id
  tags           = local.tags
}

# ============================================================
# Lambdaモジュール: 全5 Lambda関数 + DynamoDB
# fis-event-handler（Orchestrator）と4つのポストモーテムパイプラインLambdaを管理する。
# 循環参照回避: fis-event-handlerのStep Functions ARNはARN組み立て式で解決済み（変数省略可）
# ============================================================

module "lambda" {
  source = "../../modules/lambda"

  project              = local.project
  environment          = local.environment
  aws_account_id       = var.aws_account_id
  region               = "ap-northeast-1"
  step_functions_arn   = "" # fis-event-handlerはARN組み立て式を使用するため空文字で可
  s3_bucket_arn        = module.s3.bucket_arn
  s3_bucket_name       = module.s3.bucket_name
  eks_cluster_name     = module.eks.cluster_name
  eks_cluster_endpoint = module.eks.cluster_endpoint
  tags                 = local.tags

  depends_on = [module.s3]
}

# ============================================================
# Step Functionsモジュール: ポストモーテム自動生成ワークフロー
# 4つのLambda ARNを受け取りASLテンプレートを組み立てる。
# lambdaモジュールの後に定義することで循環参照を回避する。
# ============================================================

module "step_functions" {
  source = "../../modules/step_functions"

  project              = local.project
  environment          = local.environment
  region               = "ap-northeast-1"
  aws_account_id       = var.aws_account_id
  data_collector_arn   = module.lambda.data_collector_function_arn
  bedrock_analyzer_arn = module.lambda.bedrock_analyzer_function_arn
  report_formatter_arn = module.lambda.report_formatter_function_arn
  notifier_arn         = module.lambda.notifier_function_arn
  tags                 = local.tags

  depends_on = [module.lambda]
}

# ============================================================
# EventBridgeモジュール: FIS実験状態変化の検知・Lambda起動
# FIS実験のcompleted/failed/stopped イベントを検知してOrchestratorを起動する
# ============================================================

module "eventbridge" {
  source = "../../modules/eventbridge"

  project              = local.project
  environment          = local.environment
  lambda_function_arn  = module.lambda.fis_event_handler_function_arn
  lambda_function_name = module.lambda.fis_event_handler_function_name
  tags                 = local.tags
}

# ============================================================
# 環境アウトプット
# ============================================================

output "sns_topic_arn" {
  description = "ポストモーテム通知用SNSトピックのARN"
  value       = module.lambda.sns_topic_arn
}

# FIS実験テンプレート ID
output "pod_kill_experiment_template_id" {
  description = "Pod Kill実験テンプレートID"
  value       = module.fis.pod_kill_experiment_template_id
}

output "node_termination_experiment_template_id" {
  description = "Node Termination実験テンプレートID"
  value       = module.fis.node_termination_experiment_template_id
}

output "network_latency_experiment_template_id" {
  description = "Network Latency実験テンプレートID"
  value       = module.fis.network_latency_experiment_template_id
}

output "cpu_stress_experiment_template_id" {
  description = "CPU Stress実験テンプレートID"
  value       = module.fis.cpu_stress_experiment_template_id
}

# EKS情報
output "cluster_name" {
  description = "EKSクラスター名"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKSクラスターAPIエンドポイント"
  value       = module.eks.cluster_endpoint
}

# S3レポートバケット
output "s3_reports_bucket" {
  description = "ポストモーテムHTMLレポート保存S3バケット名"
  value       = module.s3.bucket_name
}

# ============================================================
# aws-auth ConfigMap：FIS実行ロールのEKS RBAC認証設定
# ============================================================

# aws-auth ConfigMap へのノードロール設定（既存のマッピング）
resource "kubernetes_config_map_v1_data" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode([
      {
        rolearn  = "arn:aws:iam::${var.aws_account_id}:role/eks-chaos-postmortem-generator-nodes-role-${local.environment}"
        username = "system:node:{{EC2PrivateDNSName}}"
        groups = [
          "system:bootstrappers",
          "system:nodes"
        ]
      }
    ])
  }

  force = true
}

# FIS実行ロール ARN を出力（aws-auth 設定で使用）
output "fis_execution_role_arn" {
  description = "FIS実行IAMロールのARN（aws-auth設定用）"
  value       = module.fis.fis_execution_role_arn
}

# ============================================================
# FIS 用 Kubernetes RBAC 権限設定（ServiceAccount ベース）
# ============================================================

# Pod 削除権限（Pod Kill 実験用）
resource "kubernetes_cluster_role_v1" "fis_pod_delete" {
  metadata {
    name = "fis-pod-delete"
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "fis_pod_delete" {
  metadata {
    name = "fis-pod-delete"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "fis-sa"
    namespace = "chaos-target"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.fis_pod_delete.metadata[0].name
  }
}

# Chaos Mesh リソース操作権限（Network Latency / CPU Stress 実験用）
resource "kubernetes_cluster_role_v1" "fis_chaos_mesh" {
  metadata {
    name = "fis-chaos-mesh"
  }

  rule {
    api_groups = ["chaos-mesh.org"]
    resources  = ["networkchaos", "stresschaos", "podchaos"]
    verbs      = ["create", "delete", "get", "list", "patch", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "fis_chaos_mesh" {
  metadata {
    name = "fis-chaos-mesh"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "fis-sa"
    namespace = "chaos-target"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.fis_chaos_mesh.metadata[0].name
  }
}
