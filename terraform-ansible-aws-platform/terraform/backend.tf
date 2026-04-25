# Terraformステートファイルのリモートバックエンド設定
terraform {
  backend "s3" {
    bucket         = "tap-terraform-state-YOUR_ACCOUNT_ID"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "tap-terraform-lock"
    encrypt        = true
  }
}
