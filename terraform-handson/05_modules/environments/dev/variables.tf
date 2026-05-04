variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
  default     = "handson"
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}

variable "allowed_ssh_cidrs" {
  description = "SSH接続を許可するCIDRリスト。本番では自分のIPを指定すること"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
