variable "project" {
  description = "プロジェクトプレフィックス"
  type        = string
  default     = "wcsl"

  validation {
    condition     = length(var.project) <= 5
    error_message = "プロジェクトプレフィックスは5文字以内にしてください (IAMロール名64文字制限のため)"
  }
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "メインリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "container_image" {
  description = "オリジンコンテナイメージ"
  type        = string
  default     = "nginx:alpine"
}

variable "domain_name" {
  description = "ACM 証明書発行対象のドメイン名"
  type        = string
}

variable "chatwork_room_id" {
  description = "Chatwork 通知先 Room ID"
  type        = string
}
