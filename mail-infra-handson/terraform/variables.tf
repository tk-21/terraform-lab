variable "domain_name" {
  description = "構築対象のドメイン名（例: mail-handson.com）"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン。東京リージョン固定"
  type        = string
  default     = "ap-northeast-1"
}

variable "admin_email" {
  description = "CloudWatchアラーム通知先の管理者メールアドレス"
  type        = string
}

variable "spf_policy" {
  description = "SPFポリシー。学習初期は ~all、本番移行前に -all へ変更する"
  type        = string
  default     = "-all"
}

variable "dmarc_policy" {
  description = "DMARCポリシー。none→quarantine→reject の順に段階移行する"
  type        = string
  default     = "quarantine"
}

variable "dmarc_pct" {
  description = "DMARCポリシーを適用するメールの割合（%）"
  type        = number
  default     = 100
}

variable "powertools_layer_version" {
  description = "Lambda Powertools V3 (Python3.12/arm64) のレイヤーバージョン番号"
  type        = number
  default     = 13
}

variable "ec2_iam_role_arn" {
  description = "PostfixをホストするEC2のIAMロールARN。VPCエンドポイントポリシーの制限に使用する。空の場合は制限なし"
  type        = string
  default     = ""
}
