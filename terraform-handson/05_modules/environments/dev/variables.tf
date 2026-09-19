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
  description = "SSH接続を許可するCIDRリスト。空の場合はSSHを開放しない"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.allowed_ssh_cidrs : can(cidrhost(cidr, 0))])
    error_message = "allowed_ssh_cidrs の各要素には有効な IPv4/IPv6 CIDR を指定してください。"
  }
}
