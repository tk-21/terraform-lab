terraform {
  backend "s3" {
    # bootstrap を apply した後、以下のコマンドで確認して書き換えること:
    #   cd ../../bootstrap && terraform output s3_bucket_name
    bucket = "handson-tfstate-<YOUR_ACCOUNT_ID>"

    key          = "handson/dev/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
