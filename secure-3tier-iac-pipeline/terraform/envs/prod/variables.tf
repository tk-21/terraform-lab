variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "stg", "dev"], var.environment)
    error_message = "environment は prod, stg, dev のいずれかである必要があります。"
  }
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID — tfstate バケット名の確認用"
  type        = string
}

variable "enable_https" {
  description = "HTTPS リスナーを有効化するフラグ。false にすると HTTP のみで動作する (ハンズオン用)"
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener (enable_https=true の場合に必須)"
  type        = string
  default     = ""
}
