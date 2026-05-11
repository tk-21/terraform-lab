variable "prefix" {
  description = "リソース名プレフィックス (例: ecl)"
  type        = string
}

variable "env" {
  description = "環境名 (例: dev)"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "fis_role_arn" {
  description = "FIS 実験テンプレートに付与する実行ロール ARN"
  type        = string
}

variable "cluster_name" {
  description = "対象 ECS クラスター名"
  type        = string
}

variable "cluster_arn" {
  description = "対象 ECS クラスター ARN"
  type        = string
}

variable "service_name" {
  description = "対象 ECS サービス名"
  type        = string
}

variable "stop_condition_task_kill_arn" {
  description = "シナリオ1 FIS 停止条件 CloudWatch アラーム ARN (RunningTaskCount < 1)"
  type        = string
}

variable "stop_condition_network_arn" {
  description = "シナリオ2 FIS 停止条件 CloudWatch アラーム ARN (HealthyHostCount = 0)"
  type        = string
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
