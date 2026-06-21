# Phase 4以降: Terraform CloudがS3+DynamoDBに代わってステート管理を担う
# 移行手順: terraform login → terraform init -migrate-state
# ステート移行後はTFC UI > Workspace > States で履歴を確認すること
terraform {
  cloud {
    # terraform login実行後に自動設定されるOrg名
    organization = "takuya-iac-lab"

    workspaces {
      name = "sample-infra-dev"
    }
  }
}
