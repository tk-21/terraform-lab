# prod 環境 S3 バックエンド設定
terraform {
  backend "s3" {
    bucket         = "sep-tfstate-REPLACE_WITH_ACCOUNT_ID"
    key            = "prod/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    kms_key_id     = "alias/sep-tfstate-key"
    dynamodb_table = "sep-tfstate-lock"
  }
}
