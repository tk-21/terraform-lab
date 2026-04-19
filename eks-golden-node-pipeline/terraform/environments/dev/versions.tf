terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Terraformリモートバックエンド（S3 + DynamoDB）
  # バケット名はデプロイ先AWSアカウントに合わせて変更する
  backend "s3" {
    bucket         = "eks-golden-node-pipeline-tfstate"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "eks-golden-node-pipeline-tflock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "eks-golden-node-pipeline"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "infrastructure-team"
      CostCenter  = "platform"
    }
  }
}
