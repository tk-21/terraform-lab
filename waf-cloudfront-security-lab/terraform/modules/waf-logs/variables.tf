variable "project" {
  description = "プロジェクトプレフィックス"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "webacl_arn" {
  description = "ログを有効化する WAF WebACL ARN"
  type        = string
}
