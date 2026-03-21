terraform {
  backend "s3" {
    bucket         = "tfstate-bedrock-finops-automation"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "tfstate-lock-bedrock-finops"
    encrypt        = true
  }
}
