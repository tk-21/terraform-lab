variable "name_prefix" { type = string }
variable "region" { type = string }
variable "account_id" { type = string }
variable "input_bucket_arn" { type = string }
variable "output_bucket_arn" { type = string }
variable "dynamodb_table_arn" { type = string }
variable "lambda_arns" { type = list(string) }
variable "sfn_arn" {
  type    = string
  default = ""
}
