# terraform/modules/api-gateway/variables.tf

variable "prefix" {
  description = "リソース名のプレフィックス。例: sap-dev"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名。API Gateway ステージ名として使用する。"
  type        = string
}

variable "lambda_arns" {
  description = "各 Lambda 関数の ARN マップ。API Gateway 統合設定で使用する。"
  type        = map(string)
}

variable "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN。null の場合は認証なし（dev 環境向け）。"
  type        = string
  default     = null
}

variable "enable_waf" {
  description = "WAF の有効化。dev ではコスト削減のため false にする。"
  type        = bool
  default     = false
}

variable "allowed_ips" {
  description = "WAF で許可する IP アドレスリスト（CIDR 形式）。enable_waf = true の場合に使用。"
  type        = list(string)
  default     = []
}
