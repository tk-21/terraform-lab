locals {
  prefix      = "smp"
  environment = var.environment
  region      = "ap-northeast-1"
  account_id  = data.aws_caller_identity.current.account_id

  common_tags = {
    Project     = "sagemaker-mlops-pipeline"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  }
}
