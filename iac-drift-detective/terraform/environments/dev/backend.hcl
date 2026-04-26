# dev環境のS3バックエンド設定
# 使用方法: terraform init -backend-config=environments/dev/backend.hcl
# バケット名はデプロイ前に実際のAWSアカウントIDに置き換えること
bucket         = "drift-detective-tfstate-REPLACE_WITH_ACCOUNT_ID"
key            = "iac-drift-detective/dev/terraform.tfstate"
region         = "ap-northeast-1"
dynamodb_table = "drift-detective-tfstate-lock"
encrypt        = true
