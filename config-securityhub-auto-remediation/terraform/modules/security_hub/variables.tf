variable "environment" {
  description = "デプロイ環境名 (dev / stg / prod)"
  type        = string
}

variable "dlq_arn" {
  description = "EventBridgeターゲット失敗時のDLQ ARN"
  type        = string
}

variable "s3_remediation_lambda_arn" {
  description = "S3修復Lambda ARN"
  type        = string
}

variable "iam_remediation_lambda_arn" {
  description = "IAM修復Lambda ARN"
  type        = string
}

variable "sg_remediation_lambda_arn" {
  description = "EC2/SG修復Lambda ARN"
  type        = string
}

variable "rds_remediation_lambda_arn" {
  description = "RDS修復Lambda ARN"
  type        = string
}
