# =============================================================================
# Terraform Remote State 設定
# S3 にステートを保存し DynamoDB でロック管理する
# =============================================================================

terraform {
  backend "s3" {
    bucket         = "tfstate-aws-infra-review-ai"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "tfstate-lock-aws-infra-review-ai"
    encrypt        = true
  }
}
