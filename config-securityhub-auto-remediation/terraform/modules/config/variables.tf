variable "config_service_role_arn" {
  description = "AWS ConfigサービスロールのARN (Phase1のiam moduleから取得)"
  type        = string
}

variable "audit_bucket_name" {
  description = "Config スナップショット配信先S3バケット名 (Phase1のaudit moduleから取得)"
  type        = string
}

variable "dlq_arn" {
  description = "EventBridgeターゲット失敗時のDLQ ARN"
  type        = string
}

variable "eventbridge_invoke_role_arn" {
  description = "EventBridgeがLambdaを実行するためのIAMロールARN"
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
