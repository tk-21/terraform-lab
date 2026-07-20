variable "project" { type = string }
variable "environment" { type = string }
variable "common_tags" { type = map(string) }
variable "private_subnet_ids" { type = list(string) }
variable "vpc_id" { type = string }
variable "dynamodb_table_name" { type = string }
variable "dynamodb_table_arn" { type = string }
variable "vpc_endpoints_sg_id" { type = string }
