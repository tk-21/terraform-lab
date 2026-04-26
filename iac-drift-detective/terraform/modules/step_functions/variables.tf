variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "sfn_role_arn" {
  description = "Step Functions IAMロールARN（Phase1で作成済み）"
  type        = string
}

variable "drift_detector_function_arn" {
  description = "drift-detector Lambda関数のARN"
  type        = string
}

variable "bedrock_analyzer_function_arn" {
  description = "bedrock-analyzer Lambda関数のARN"
  type        = string
}

variable "pr_creator_function_arn" {
  description = "pr-creator Lambda関数のARN"
  type        = string
}

variable "log_group_arn" {
  description = "Step Functions用CloudWatch LogsグループのARN（Phase1で作成済み）"
  type        = string
}

variable "tags" {
  description = "リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
