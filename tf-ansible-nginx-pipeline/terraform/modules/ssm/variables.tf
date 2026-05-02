variable "name_prefix" {
  description = "SSMパラメータパスのプレフィックス（例: handson-dev）"
  type        = string
}

variable "nginx_port" {
  description = "nginxリスンポート番号"
  type        = number
  default     = 80
}

variable "nginx_worker_processes" {
  description = "nginxワーカープロセス数（autoでCPUコア数に自動調整）"
  type        = string
  default     = "auto"
}
