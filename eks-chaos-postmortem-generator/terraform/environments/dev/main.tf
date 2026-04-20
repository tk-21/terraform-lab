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

# ============================================================
# ローカル変数: 環境設定の一元管理
# ============================================================

locals {
  project      = "eks-chaos-postmortem-generator"
  environment  = "dev"
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
  cluster_name = module.eks.cluster_name
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
