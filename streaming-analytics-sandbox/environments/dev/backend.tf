terraform {
  backend "s3" {
    bucket         = "tfstate-streaming-analytics-sandbox"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock-streaming-analytics"
  }
}
