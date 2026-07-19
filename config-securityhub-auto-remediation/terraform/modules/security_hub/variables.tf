variable "environment" {
  description = "デプロイ環境名 (dev / stg / prod)"
  type        = string
}

variable "dlq_arn" {
  description = "EventBridgeターゲット失敗時のDLQ ARN"
  type        = string
}

# Phase4でLambda ARNが確定したら設定する。初回applyはnullで可。
variable "s3_remediation_lambda_arn" {
  description = "S3修復Lambda ARN (Phase4で設定)"
  type        = string
  default     = null
}

variable "iam_remediation_lambda_arn" {
  description = "IAM修復Lambda ARN (Phase4で設定)"
  type        = string
  default     = null
}

variable "sg_remediation_lambda_arn" {
  description = "EC2/SG修復Lambda ARN (Phase4で設定)"
  type        = string
  default     = null
}

variable "rds_remediation_lambda_arn" {
  description = "RDS修復Lambda ARN (Phase4で設定)"
  type        = string
  default     = null
}
