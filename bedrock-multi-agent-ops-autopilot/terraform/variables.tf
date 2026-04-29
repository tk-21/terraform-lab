variable "environment" {
  description = "デプロイ環境"
  type        = string
  default     = "dev"
}

variable "chatwork_room_id" {
  description = "Chatwork通知先ルームID（SSM経由で管理）"
  type        = string
  sensitive   = true
  default     = ""
}

variable "alert_threshold_cost_usd" {
  description = "コスト異常検知の閾値（USD）"
  type        = number
  default     = 50
}
