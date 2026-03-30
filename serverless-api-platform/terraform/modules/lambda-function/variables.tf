# terraform/modules/lambda-function/variables.tf

variable "function_name" {
  description = "Lambda 関数名。命名規則: sap-<env>-<操作>-<リソース>"
  type        = string
}

variable "description" {
  description = "Lambda 関数の説明。"
  type        = string
  default     = ""
}

variable "handler" {
  description = "Lambda ハンドラー。例: handler.handler"
  type        = string
  default     = "handler.handler"
}

variable "runtime" {
  description = "Lambda ランタイム。"
  type        = string
  default     = "python3.12"
}

variable "architectures" {
  description = "Lambda アーキテクチャ。arm64 は x86_64 より約20% 安価。"
  type        = list(string)
  default     = ["arm64"]
}

variable "timeout" {
  description = "Lambda タイムアウト（秒）。API GW 統合の場合は 25 を推奨。"
  type        = number
  default     = 25
}

variable "memory_size" {
  description = "Lambda メモリサイズ（MB）。メモリを増やすと CPU 比例して増加する。"
  type        = number
  default     = 256
}

variable "source_dir" {
  description = "Lambda ソースコードのディレクトリパス。zip に圧縮されてデプロイされる。"
  type        = string
}

variable "environment_variables" {
  description = "Lambda 環境変数。秘匿情報は SSM Parameter Store 経由で取得すること。"
  type        = map(string)
  default     = {}
}

variable "execution_role_arn" {
  description = "Lambda 実行ロールの ARN。最小権限で設定すること。"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持日数。dev は短め、prod は長めに設定する。"
  type        = number
  default     = 14
}

variable "event_source_arn" {
  description = "イベントソース（DynamoDB Streams など）の ARN。null の場合はマッピングを作成しない。"
  type        = string
  default     = null
}
