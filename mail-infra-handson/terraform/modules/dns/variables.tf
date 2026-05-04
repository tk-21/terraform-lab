variable "domain_name" {
  description = "構築対象のドメイン名（例: mail-handson.com）"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン。SES受信エンドポイントのMXレコードに使用する"
  type        = string
  default     = "ap-northeast-1"
}

variable "spf_policy" {
  description = "SPFレコードの末尾ポリシー。~all（ソフトフェイル）から -all（ハードフェイル）へ段階移行する"
  type        = string
  default     = "-all"
  validation {
    condition     = contains(["~all", "-all"], var.spf_policy)
    error_message = "spf_policy は '~all' または '-all' を指定してください"
  }
}

variable "dmarc_policy" {
  description = "DMARCポリシー。none→quarantine→reject の順に段階移行する"
  type        = string
  default     = "quarantine"
  validation {
    condition     = contains(["none", "quarantine", "reject"], var.dmarc_policy)
    error_message = "dmarc_policy は 'none', 'quarantine', 'reject' のいずれかを指定してください"
  }
}

variable "dmarc_pct" {
  description = "DMARCポリシーを適用するメールの割合（%）。段階移行時は10→50→100と増やす"
  type        = number
  default     = 100
  validation {
    condition     = var.dmarc_pct >= 0 && var.dmarc_pct <= 100
    error_message = "dmarc_pct は 0〜100 の範囲で指定してください"
  }
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
