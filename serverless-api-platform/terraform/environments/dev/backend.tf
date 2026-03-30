# terraform/environments/dev/backend.tf
#
# Terraformリモートステートの設定。
# bootstrap.sh 実行後に `terraform init` を実行することで有効化される。
#
# バケット名の <account_id> は bootstrap.sh 実行時に確定する。
# 実際のアカウントIDに置き換えること。

terraform {
  backend "s3" {
    # bootstrap.sh で作成されたバケット名に合わせること
    # 例: sap-tfstate-123456789012
    bucket = "sap-tfstate-<account_id>"

    # 環境ごとにステートファイルのパスを分離することで、
    # dev/prod の誤操作を防ぐ
    key = "dev/terraform.tfstate"

    region = "ap-northeast-1"

    # DynamoDB によるステートロック。
    # 複数人が同時に apply するとステートが壊れるため必須。
    dynamodb_table = "sap-tfstate-lock"

    # ステートファイル自体の暗号化（S3バケット側の暗号化と二重化）
    encrypt = true
  }
}
