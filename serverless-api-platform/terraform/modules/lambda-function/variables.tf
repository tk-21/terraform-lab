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
  description = "Lambda ハンドラー。<モジュール名>.<関数名> の形式。"
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
  description = <<-EOT
    Lambda タイムアウト（秒）。
    API Gateway 統合の場合は 25 を推奨。
    API GW の統合タイムアウト上限（29秒）より短く設定することで、
    API GW 側がタイムアウトする前に Lambda 側でエラーをハンドルし
    クライアントに適切なエラーレスポンスを返せる。
    非同期処理（stream-processor 等）は呼び出し元で上書きすること。
  EOT
  type        = number
  default     = 25
}

variable "memory_size" {
  description = "Lambda メモリサイズ（MB）。メモリを増やすと vCPU も比例して増加する。"
  type        = number
  default     = 256
}

variable "source_dir" {
  description = "Lambda ソースコードのディレクトリパス。archive_file で zip 化されてデプロイされる。"
  type        = string
}

variable "deployment_bucket_name" {
  description = "Lambda デプロイパッケージ（zip）をアップロードする S3 バケット名。"
  type        = string
}

variable "environment_variables" {
  description = <<-EOT
    Lambda 環境変数。
    秘匿情報は SSM Parameter Store 経由で取得すること（直接ハードコード禁止）。
    POWERTOOLS_SERVICE_NAME / LOG_LEVEL / POWERTOOLS_METRICS_NAMESPACE は
    モジュールが自動付与するため指定不要（呼び出し元の値で上書きも可能）。
  EOT
  type        = map(string)
  default     = {}
}

variable "log_level" {
  description = "Lambda Powertools のログレベル。dev: DEBUG も可。prod: WARNING を推奨。"
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], var.log_level)
    error_message = "log_level は DEBUG / INFO / WARNING / ERROR / CRITICAL のいずれかを指定してください。"
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持日数。dev: 14日、prod: 90日を推奨。"
  type        = number
  default     = 14
}

variable "reserved_concurrent_executions" {
  description = <<-EOT
    Lambda の予約済み同時実行数。
    デフォルト 10 の意図:
    未設定（-1）のままにすると、バグや DDoS 等によるリクエスト急増時に
    Lambda が際限なくスケールし、DynamoDB スロットリングや
    Lambda コスト爆発を引き起こすリスクがある。
    10 を上限とすることで「暴走防止のサーキットブレーカー」として機能させる。
    トラフィック見積もりに応じて呼び出し元で上書きすること。
    -1 を指定すると予約なし（アカウント上限まで自動スケール）になる。
  EOT
  type        = number
  default     = 10
}

variable "additional_policy_statements" {
  description = <<-EOT
    Lambda 実行ロールに追加するインライン IAM ポリシーのステートメント。
    DynamoDB テーブルへのアクセス権限など、関数固有の権限をここで指定する。
    最小権限原則に従い、必要なリソースのみを resources に列挙すること。
  EOT
  type = list(object({
    effect    = string
    actions   = list(string)
    resources = list(string)
  }))
  default = []
}

variable "provisioned_concurrency" {
  description = <<-EOT
    プロビジョンド同時実行数。0 の場合はプロビジョンドコンカレンシーを設定しない。
    prod 環境でコールドスタートを排除したい場合に 1 以上を指定する。
    コストが発生するため dev では 0 を推奨。
  EOT
  type    = number
  default = 0
}

variable "event_source_arn" {
  description = "イベントソース（DynamoDB Streams 等）の ARN。null の場合はマッピングを作成しない。"
  type        = string
  default     = null
}

variable "execution_role_arn" {
  description = <<-EOT
    Lambda 実行ロールの ARN。
    指定した場合はモジュール内の IAM ロール作成をスキップし、指定されたロールを使用する。
    module "iam" で一元管理するロールを渡す場合に使用する。
    null の場合はモジュール内でロールを自動作成する（スタンドアロン利用）。
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "全リソースに付与するタグ。environments/ の common_tags を渡す。"
  type        = map(string)
  default     = {}
}
