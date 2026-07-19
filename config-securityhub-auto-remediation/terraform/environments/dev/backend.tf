terraform {
  # バックエンドバケットはscripts/init-backend.shで事前に作成すること
  backend "s3" {
    bucket         = "csar-tfstate-REPLACE_ACCOUNT_ID"
    key            = "config-securityhub-auto-remediation/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "csar-tfstate-lock"
  }
}
