terraform {
  backend "s3" {
    bucket         = "istio-eks-tfstate-REPLACE_WITH_ACCOUNT_ID"
    key            = "istio-eks-service-mesh/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "istio-eks-tfstate-lock"
    encrypt        = true
  }
}
