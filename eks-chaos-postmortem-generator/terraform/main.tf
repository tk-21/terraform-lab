# =============================================================================
# Terraformバックエンド・プロバイダー設定
# EKS Chaos Postmortem Generator プロジェクト
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    # EKS OIDCプロバイダーの証明書取得に使用
    tls = {
      source  = "hashicorp/tls"
      version = "~> 3.0"
    }
  }

  # S3バックエンドでTerraformステートを管理
  # partial configuration: 実行時に -backend-config=backend.hcl で上書き可能
  # 例: terraform init -backend-config="bucket=my-tfstate-bucket"
  backend "s3" {
    bucket = "eks-chaos-postmortem-tfstate"
    key    = "eks-chaos-postmortem/terraform.tfstate"
    region = "ap-northeast-1"
  }
}

# AWSプロバイダー設定
# default_tagsで全リソースに共通タグを付与（Environmentはモジュール側で追加）
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = "eks-chaos-postmortem-generator"
      ManagedBy  = "terraform"
      Owner      = "takuya"
      CostCenter = "portfolio"
    }
  }
}
