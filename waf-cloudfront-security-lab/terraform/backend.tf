# リモートステート設定
# バケット名・DynamoDB テーブル名は事前に手動作成すること
terraform {
  backend "s3" {
    bucket         = "wcsl-tfstate-YOUR_ACCOUNT_ID"
    key            = "waf-cloudfront-security-lab/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "wcsl-tfstate-lock"
    encrypt        = true
  }
}
