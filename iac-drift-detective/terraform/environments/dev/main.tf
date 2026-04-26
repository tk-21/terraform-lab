# dev環境エントリーポイント。ルートモジュールを呼び出し、全変数をterraform.tfvarsから受け取る。

terraform {
  required_version = ">= 1.9.0"
}

provider "aws" {
  region = "ap-northeast-1"
}

module "drift_detective" {
  source = "../../"

  aws_region               = var.aws_region
  bedrock_region           = var.bedrock_region
  environment              = var.environment
  project_name             = var.project_name
  github_owner             = var.github_owner
  github_repo              = var.github_repo
  chatwork_room_id         = var.chatwork_room_id
  monitored_tfstate_bucket = var.monitored_tfstate_bucket
  monitored_tfstate_key    = var.monitored_tfstate_key
}
