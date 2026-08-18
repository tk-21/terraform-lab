# Phase 1〜3: Atlantis が S3 + DynamoDB でステートとロックを管理する
# Phase 4 で HCP Terraform へ移行する際は cloud ブロックへ変更し、
# terraform init -migrate-state を実行すること
terraform {
  backend "s3" {
    bucket         = "tfstate-pr-driven-iac-lab-999828867039"
    key            = "sample-infra/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "tfstate-lock-pr-driven-iac-lab"
    encrypt        = true
  }
}
