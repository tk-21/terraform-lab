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
      Phase       = "ecs"
    }
  }
}

# Foundation の出力値を参照
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
  ecr_api_url        = data.terraform_remote_state.foundation.outputs.ecr_api_url
  ecr_worker_url     = data.terraform_remote_state.foundation.outputs.ecr_worker_url
  sqs_queue_url      = data.terraform_remote_state.foundation.outputs.sqs_queue_url
  sqs_queue_arn      = data.terraform_remote_state.foundation.outputs.sqs_queue_arn
  # foundationのoutput名はecs_exec_role_arn（execution roleを指す）
  execution_role_arn = data.terraform_remote_state.foundation.outputs.ecs_exec_role_arn
  task_role_arn      = data.terraform_remote_state.foundation.outputs.ecs_task_role_arn
}
