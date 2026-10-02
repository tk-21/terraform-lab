terraform {
  backend "s3" {
    # [設計意図] bucket はアカウントID等を含むためコードに直書きせず、init 時に渡す
    # [注意] terraform init -backend-config="bucket=<bootstrap.sh が作成したバケット名>"
    key            = "prod/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "s3t-prod-tfstate-lock"
  }
}
