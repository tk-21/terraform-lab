terraform {
  backend "s3" {
    # [注意] bootstrap.sh 実行後に出力されるアカウントIDで bucket 名を確認すること
    # bucket = "s3t-prod-tfstate-{AWSアカウントID}"  # bootstrap.sh 実行後に設定
    key            = "prod/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "s3t-prod-tfstate-lock"
  }
}
