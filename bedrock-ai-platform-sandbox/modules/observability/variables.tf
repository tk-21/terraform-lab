variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "router_lambda_name" {
  description = "Router Lambda function name"
  type        = string
}

variable "cost_controller_lambda_name" {
  description = "Cost controller Lambda function name"
  type        = string
}

variable "action_handler_lambda_name" {
  description = "Bedrock Agent action handler Lambda function name"
  type        = string
}

variable "api_id" {
  description = "API Gateway HTTP API ID"
  type        = string
}

variable "tenant_table_name" {
  description = "DynamoDB tenant table name"
  type        = string
}

variable "usage_table_name" {
  description = "DynamoDB usage table name"
  type        = string
}

variable "alert_topic_arn" {
  description = "SNS topic ARN for alarm notifications (from cost-controller)"
  type        = string
}

variable "cloudtrail_log_group" {
  description = "CloudWatch Log Group name for Bedrock CloudTrail"
  type        = string
}

variable "lambda_error_threshold" {
  description = "CloudWatch Alarm threshold for Lambda error count per evaluation period"
  type        = number
  default     = 5
}

variable "api_5xx_threshold" {
  description = "CloudWatch Alarm threshold for API Gateway 5xx count per evaluation period"
  type        = number
  default     = 10
}

variable "dashboard_refresh_interval" {
  description = "CloudWatch dashboard auto-refresh interval in seconds (0 = off)"
  type        = number
  default     = 300
}
