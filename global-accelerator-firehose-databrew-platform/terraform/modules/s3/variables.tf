variable "name_prefix" {
  description = "Prefix applied to all resource names (e.g. gaf)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID used to ensure globally unique bucket names"
  type        = string
}
