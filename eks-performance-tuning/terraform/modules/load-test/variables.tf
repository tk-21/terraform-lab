variable "project_name" {
  description = "Project name prefix for resource naming"
  type        = string
  default     = "ept"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "app_base_url" {
  description = "URL of the sample app under test"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where Fargate tasks will run"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for Fargate tasks"
  type        = list(string)
}

variable "aws_region" {
  description = "AWS region for resource deployment"
  type        = string
  default     = "ap-northeast-1"
}
