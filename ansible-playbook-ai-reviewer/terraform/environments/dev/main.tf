# dev環境エントリーポイント
# ルートモジュールを参照して dev環境のリソースをデプロイ

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "terraform-state-ansible-ai-reviewer"
    key     = "ansible-playbook-ai-reviewer/dev/terraform.tfstate"
    region  = "ap-northeast-1"
    encrypt = true
    # S3 ネイティブロック (Terraform 1.10+)。DynamoDB テーブルは不要
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

module "ansible_ai_reviewer" {
  source = "../../"

  environment           = var.environment
  aws_region            = var.aws_region
  bedrock_region        = var.bedrock_region
  lambda_timeout        = var.lambda_timeout
  lambda_memory         = var.lambda_memory
  api_gateway_stage     = var.api_gateway_stage
  github_token_ssm_path = var.github_token_ssm_path
}

output "api_endpoint" {
  value = module.ansible_ai_reviewer.api_endpoint
}

output "lambda_function_name" {
  value = module.ansible_ai_reviewer.lambda_function_name
}
