variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "environment" {
  description = "環境名"
  type        = string
}

variable "common_tags" {
  description = "全リソース共通タグ"
  type        = map(string)
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "incident_investigator_function_arn" {
  description = "incident_investigator Lambda ARN"
  type        = string
}

variable "cost_optimizer_function_arn" {
  description = "cost_optimizer Lambda ARN"
  type        = string
}

variable "remediation_function_arn" {
  description = "remediation Lambda ARN"
  type        = string
}

variable "reporter_function_arn" {
  description = "reporter Lambda ARN"
  type        = string
}

variable "supervisor_agent_role_arn" {
  description = "Supervisor Bedrock AgentのIAMロールARN"
  type        = string
}
