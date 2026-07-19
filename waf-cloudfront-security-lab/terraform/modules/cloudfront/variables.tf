variable "project" {
  description = "プロジェクトプレフィックス"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "alb_dns_name" {
  description = "オリジン ALB の DNS 名"
  type        = string
}

variable "webacl_arn" {
  description = "WAF WebACL ARN (us-east-1 で作成済みのもの)"
  type        = string
}

variable "acm_certificate_arn_use1" {
  description = "CloudFront 用 ACM 証明書 ARN (us-east-1)"
  type        = string
}

variable "cloudfront_secret" {
  description = "CloudFront → ALB 間の認証用シークレット (SSM Parameter Store から取得)"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "CloudFront ディストリビューションに設定するカスタムドメイン名"
  type        = string
}
