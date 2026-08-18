terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # bootstrap apply後にAWSアカウントIDを確認して置き換える
    bucket         = "tfstate-pr-driven-iac-lab-999828867039"
    key            = "atlantis-infra/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "tfstate-lock-pr-driven-iac-lab"
    encrypt        = true
  }
}

provider "aws" {
  region = "ap-northeast-1"
}
