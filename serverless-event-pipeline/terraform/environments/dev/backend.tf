# S3 バックエンド設定
# KMS 暗号化 + バージョニングでステートファイルを保護する。
# DynamoDB によるステートロックで並行 apply を防止する。
#
# 注意: backend ブロック内では変数補間が使用できない。
# `terraform init -backend-config="bucket=sep-tfstate-<account_id>"` で上書きするか、
# scripts/bootstrap.sh 実行後に account_id を手動で設定すること。
terraform {
  backend "s3" {
    # account_id は terraform init 時に -backend-config で渡すこと
    # 例: terraform init -backend-config="bucket=sep-tfstate-123456789012"
    bucket         = "sep-tfstate-REPLACE_WITH_ACCOUNT_ID"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    kms_key_id     = "alias/sep-tfstate-key"
    dynamodb_table = "sep-tfstate-lock"
  }
}
