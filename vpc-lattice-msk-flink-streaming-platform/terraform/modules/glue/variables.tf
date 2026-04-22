variable "name_prefix" {
  description = "Resource naming prefix"
  type        = string
}

variable "output_bucket_name" {
  description = "S3 bucket name for Parquet output and Athena results"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
