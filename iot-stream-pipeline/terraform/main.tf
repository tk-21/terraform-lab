# ap-northeast-1 (東京) リージョンを使用
# 理由: 物理的に近く、レイテンシが低い
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# アカウントIDをハードコードせずdata sourceで取得する
# 理由: 複数アカウントでの再利用性とセキュリティのため
data "aws_caller_identity" "current" {}

module "kinesis" {
  source       = "./modules/kinesis"
  project_name = var.project_name
}

module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
}

module "apigateway" {
  source = "./modules/apigateway"

  project_name         = var.project_name
  reader_invoke_arn    = module.lambda.reader_invoke_arn
  reader_function_name = module.lambda.reader_function_name
}

# image URIはECRプッシュ後に確定するため、variableとして渡す
module "lambda" {
  source = "./modules/lambda"

  project_name        = var.project_name
  processor_image_uri = var.processor_image_uri
  reader_image_uri    = var.reader_image_uri
  dynamodb_table_name = module.dynamodb.table_name
  dynamodb_table_arn  = module.dynamodb.table_arn
  kinesis_stream_arn  = module.kinesis.stream_arn
}
