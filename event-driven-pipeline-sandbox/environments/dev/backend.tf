terraform {
  backend "s3" {
    bucket         = "tfstate-event-driven-pipeline"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock-event-pipeline"
  }
}
