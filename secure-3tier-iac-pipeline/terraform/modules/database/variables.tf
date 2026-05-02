variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure"
  type        = string
}

variable "data_subnet_ids" {
  description = "Data subnet IDs for RDS Aurora placement (data tier)"
  type        = list(string)
}

variable "rds_sg_id" {
  description = "Security Group ID for RDS Aurora"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for RDS storage encryption"
  type        = string
}

variable "rds_secret_arn" {
  description = "Secrets Manager secret ARN containing RDS master credentials (username/password JSON)"
  type        = string
}

variable "min_capacity" {
  description = "Minimum Aurora Serverless v2 capacity in ACU"
  type        = number
  default     = 0.5
}

variable "max_capacity" {
  description = "Maximum Aurora Serverless v2 capacity in ACU"
  type        = number
  default     = 4.0
}

variable "deletion_protection" {
  description = "Enable deletion protection on the Aurora cluster. Set to false before destroy."
  type        = bool
  default     = true
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
