terraform {
  required_version = "~> 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# -----------------------------------------------------------------------
# S3 モジュール（Analyzer 結果保存バケット）
# -----------------------------------------------------------------------
module "s3" {
  source = "./modules/s3"

  project_name = var.project_name
  environment  = var.environment
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------
# IAM モジュール（Lambda 実行ロール）
# S3 モジュールの出力（bucket_arn）に依存
# -----------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_name            = var.project_name
  environment             = var.environment
  aws_region              = var.aws_region
  results_bucket_arn      = module.s3.bucket_arn
  github_token_secret_arn = var.github_token_secret_arn
  chatwork_secret_arn     = var.chatwork_secret_arn
  bedrock_model_id        = var.bedrock_model_id
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------
# Access Analyzer モジュール（外部アクセス + 未使用アクセス検出）
# 他モジュールへの依存なし
# -----------------------------------------------------------------------
module "access_analyzer" {
  source = "./modules/access_analyzer"

  project_name      = var.project_name
  environment       = var.environment
  unused_access_age = 90
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------
# Lambda モジュール（analyzer-trigger / policy-advisor）
# IAM モジュールと S3 モジュールの出力に依存
# -----------------------------------------------------------------------
module "lambda" {
  source = "./modules/lambda"

  project_name              = var.project_name
  environment               = var.environment
  aws_region                = var.aws_region
  analyzer_trigger_role_arn = module.iam.analyzer_trigger_role_arn
  policy_advisor_role_arn   = module.iam.policy_advisor_role_arn
  results_bucket_name       = module.s3.bucket_name
  github_token_secret_arn   = var.github_token_secret_arn
  chatwork_secret_arn       = var.chatwork_secret_arn
  chatwork_room_id          = var.chatwork_room_id
  github_owner              = var.github_owner
  github_repo               = var.github_repo
  bedrock_model_id          = var.bedrock_model_id
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------
# EventBridge モジュール（毎週月曜 09:00 JST スケジューラー）
# Lambda モジュールの出力に依存
# -----------------------------------------------------------------------
module "eventbridge" {
  source = "./modules/eventbridge"

  project_name                   = var.project_name
  environment                    = var.environment
  aws_region                     = var.aws_region
  analyzer_trigger_function_arn  = module.lambda.analyzer_trigger_function_arn
  analyzer_trigger_function_name = module.lambda.analyzer_trigger_function_name
  schedule_expression            = "cron(0 0 ? * MON *)"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
