variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "aws_account_id" {
  type = string
}

variable "project_name" {
  type    = string
  default = "eks-chaos-cell"
}

variable "owner" {
  type = string
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type    = string
  default = "eks-chaos-cell"
}

variable "create_oidc_provider" {
  type    = bool
  default = true
}
