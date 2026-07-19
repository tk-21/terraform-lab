terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # ラボ環境のためローカルステートを使用
  # 本番: S3 backend + DynamoDB ロック
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "ecs-eks-deepdive"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

variable "region" {
  description = "AWSリージョン"
  default     = "ap-northeast-1"
}

variable "project" {
  description = "プロジェクト名（全リソースの命名プレフィックス）"
  default     = "deepdive"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
