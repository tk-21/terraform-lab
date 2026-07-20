locals {
  project     = "order-pipeline"
  environment = "dev"
  region      = "ap-northeast-1"

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}
