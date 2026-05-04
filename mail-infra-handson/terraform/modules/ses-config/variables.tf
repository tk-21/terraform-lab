variable "ses_identity_name" {
  description = "SES Email Identity名（ドメイン名）。Configuration Setと紐付けるために使用する"
  type        = string
}

variable "bounce_sns_topic_arn" {
  description = "バウンス通知SNSトピックのARN。Configuration Setのイベント転送先"
  type        = string
}

variable "complaint_sns_topic_arn" {
  description = "苦情通知SNSトピックのARN。Configuration Setのイベント転送先"
  type        = string
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
