variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "lambda_role_arn" {
  description = "pr-creator LambdaのIAMロールARN（Phase1で作成済み）"
  type        = string
}

variable "github_owner" {
  description = "GitHub リポジトリオーナー名"
  type        = string
}

variable "github_repo" {
  description = "GitHub リポジトリ名"
  type        = string
}

variable "chatwork_room_id" {
  description = "Chatwork 通知先ルームID"
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch Logsグループ名（Phase1で作成済み）"
  type        = string
}

variable "tags" {
  description = "リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
