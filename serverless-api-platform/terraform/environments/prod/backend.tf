# terraform/environments/prod/backend.tf
#
# prod 環境のリモートステート設定。
# dev と同じバケットを使用するが、key パスで環境を分離する。

terraform {
  backend "s3" {
    bucket         = "sap-tfstate-<account_id>"
    key            = "prod/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "sap-tfstate-lock"
    encrypt        = true
  }
}
