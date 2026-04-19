# dev環境エントリーポイント
# ルートモジュールを参照して dev環境のリソースをデプロイ

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "terraform-state-ansible-ai-reviewer"
    key            = "ansible-playbook-ai-reviewer/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "terraform-lock-ansible-ai-reviewer"
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

module "ansible_ai_reviewer" {
  source = "../../"

  environment           = "dev"
  aws_region            = "ap-northeast-1"
  bedrock_region        = "us-east-1"
  lambda_timeout        = 300
  lambda_memory         = 512
  api_gateway_stage     = "v1"
  github_token_ssm_path = "/ansible-ai-reviewer/github-token"
}

output "api_endpoint" {
  value = module.ansible_ai_reviewer.api_endpoint
}

output "lambda_function_name" {
  value = module.ansible_ai_reviewer.lambda_function_name
}
