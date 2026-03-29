variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "project_name" {
  type    = string
  default = "knowledge-bot"
}

variable "owner" {
  type    = string
  default = "infra"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "cluster_version" {
  type    = string
  default = "1.29"
}

variable "app_image_tag" {
  type    = string
  default = "dev"
}

variable "bedrock_model_id" {
  type    = string
  default = "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

variable "aoss_index_name" {
  type    = string
  default = "knowledge-bot-index"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository in owner/name format allowed to assume CI role"
  default     = "YOURORG/knowledge-bot"
}

variable "enable_lbc" {
  type        = bool
  description = "Enable AWS Load Balancer Controller resources managed by Terraform/Helm"
  default     = false
}
