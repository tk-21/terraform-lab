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
  description = <<-EOT
    Lambda 関数 ARN のマップ。aws_lambda_permission（invoke 許可）で使用する。
    キー: list_items / create_item / get_item / update_item / delete_item
    値: aws_lambda_function.this.arn（function_arn）
  EOT
  type        = map(string)
}

variable "lambda_invoke_arns" {
  description = <<-EOT
    Lambda invoke ARN のマップ。API Gateway 統合の URI として使用する。
    キー: list_items / create_item / get_item / update_item / delete_item
    値: aws_lambda_function.this.invoke_arn
    ※ function_arn と形式が異なる点に注意:
       invoke_arn = arn:aws:apigateway:{region}:lambda:path/2015-03-31/functions/{arn}/invocations
  EOT
  type        = map(string)
}

variable "cognito_user_pool_arn" {
  description = <<-EOT
    Cognito User Pool ARN。null の場合は認証なし（dev 環境向け）。
    prod では cognito モジュールの user_pool_arn を渡すこと。
  EOT
  type        = string
  default     = null
}

variable "authorizer_ttl" {
  description = <<-EOT
    Cognito オーソライザーの結果キャッシュ TTL（秒）。
    300秒（5分）が推奨。0 にするとキャッシュなし（全リクエストで検証）。
  EOT
  type        = number
  default     = 300
}

variable "throttling_rate_limit" {
  description = <<-EOT
    API Gateway のスロットリングレート上限（req/s）。
    DDoS 対策とコスト上限として機能する。
    dev デフォルト: 1000 req/s。prod では実績値の 1.5 倍程度に設定する。
  EOT
  type        = number
  default     = 1000
}

variable "throttling_burst_limit" {
  description = <<-EOT
    バーストリミット（同時処理可能な最大リクエスト数）。
    rate_limit の 50% 程度を目安に設定する。
  EOT
  type        = number
  default     = 500
}

variable "log_retention_days" {
  description = "CloudWatch Logs（アクセスログ）の保持日数。dev: 14日、prod: 90日を推奨。"
  type        = number
  default     = 14
}

variable "enable_waf" {
  description = "WAF の有効化。dev ではコスト削減のため false にする（prod のみ true）。"
  type        = bool
  default     = false
}

variable "allowed_ips" {
  description = "WAF で許可する IP アドレスリスト（CIDR 形式）。enable_waf = true の場合に使用。"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "全リソースに付与するタグ。environments/ の common_tags を渡す。"
  type        = map(string)
  default     = {}
}
