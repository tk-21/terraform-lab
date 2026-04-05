variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "chatwork_room_id" {
  description = "Chatwork 通知先ルーム ID（環境変数として Lambda に渡す）"
  type        = string
  default     = "0"
}

variable "chatwork_token_ssm_path" {
  description = "Chatwork API トークンを格納した SSM Parameter Store のパス"
  type        = string
}
