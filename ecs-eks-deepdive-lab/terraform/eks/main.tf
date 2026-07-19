terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = {
      Project     = "ecs-eks-deepdive"
      Environment = "lab"
      Phase       = "eks"
    }
  }
}

data "terraform_remote_state" "foundation" {
  backend = "local"
  config = {
    path = "../foundation/terraform.tfstate"
  }
}

locals {
  vpc_id             = data.terraform_remote_state.foundation.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  public_subnet_ids  = data.terraform_remote_state.foundation.outputs.public_subnet_ids
  sqs_queue_url      = data.terraform_remote_state.foundation.outputs.sqs_queue_url
  sqs_queue_arn      = data.terraform_remote_state.foundation.outputs.sqs_queue_arn
  eks_node_role_arn  = data.terraform_remote_state.foundation.outputs.eks_node_role_arn
  aws_account_id     = data.terraform_remote_state.foundation.outputs.aws_account_id
  cluster_name       = "deepdive-eks"
}

data "aws_caller_identity" "current" {}
