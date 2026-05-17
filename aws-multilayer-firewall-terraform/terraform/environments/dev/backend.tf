terraform {
  backend "s3" {
    # バケット名: amf-tfstate-{AWS_ACCOUNT_ID} に置き換えること
    bucket         = "amf-tfstate-REPLACE_WITH_ACCOUNT_ID"
    key            = "aws-multilayer-firewall/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "amf-tfstate-lock"
    encrypt        = true
  }
}
