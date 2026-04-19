# S3バックエンド設定
# バケット名・DynamoDBテーブルは環境ごとに変数化
terraform {
  backend "s3" {
    bucket         = "terraform-state-ansible-ai-reviewer"
    key            = "ansible-playbook-ai-reviewer/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "terraform-lock-ansible-ai-reviewer"
  }
}
