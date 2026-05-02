variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for CloudWatch Logs and SSM session encryption"
  type        = string
}

variable "session_logs_bucket_name" {
  description = "S3 bucket name for SSM Session Manager session logs (created in security module)"
  type        = string
}

variable "cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  type        = string
}

variable "reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  type        = string
}

variable "port" {
  description = "Aurora cluster port"
  type        = number
  default     = 3306
}

variable "db_name" {
  description = "Aurora database name"
  type        = string
  default     = "appdb"
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
