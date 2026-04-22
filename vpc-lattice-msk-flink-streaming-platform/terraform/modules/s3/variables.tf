variable "name_prefix" {
  description = "Prefix used for naming all resources in this module"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID used to ensure globally unique S3 bucket names"
  type        = string
}

variable "tags" {
  description = "Map of tags to apply to all resources"
  type        = map(string)
  default     = {}
}
