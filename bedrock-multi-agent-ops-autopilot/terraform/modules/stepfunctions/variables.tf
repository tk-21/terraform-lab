variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "environment" {
  description = "環境名"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "common_tags" {
  description = "全リソース共通タグ"
  type        = map(string)
}

variable "execution_history_table_name" {
  description = "Agent実行履歴DynamoDBテーブル名"
  type        = string
}

variable "execution_history_table_arn" {
  description = "Agent実行履歴DynamoDBテーブルARN"
  type        = string
}

variable "cloudwatch_log_group_arn" {
  description = "Step Functions実行ログ用CloudWatch LogsグループARN"
  type        = string
}

variable "supervisor_agent_id" {
  description = "Supervisor Bedrock Agent ID"
  type        = string
}

variable "supervisor_agent_alias_id" {
  description = "Supervisor Bedrock Agent エイリアスID"
  type        = string
}

variable "alert_threshold_cost_usd" {
  description = "コスト異常検知の閾値（USD）"
  type        = number
  default     = 50
}
