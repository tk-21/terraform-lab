terraform {
  backend "s3" {
    bucket         = "tfstate-bedrock-ai-platform-sandbox"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock-bedrock-ai-platform"
  }
}
