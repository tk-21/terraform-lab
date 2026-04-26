# terraform init -backend-config=environments/dev/backend.hcl でバケット名等を注入する
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # バケット名・DynamoDBテーブル名は environments/{env}/backend.hcl で上書きする
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "infra-team"
      CostCenter  = "portfolio"
    }
  }
}

# BedrockはClaude Sonnet 3.5が利用可能なus-east-1を使用
provider "aws" {
  alias  = "bedrock"
  region = var.bedrock_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "infra-team"
      CostCenter  = "portfolio"
    }
  }
}
