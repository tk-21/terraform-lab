# lambda-function モジュールの変数定義

# ── 必須パラメータ ────────────────────────────────────────────

variable "function_name" {
  description = "Lambda 関数名。命名規則: sep-<env>-<役割>（例: sep-prod-ingestor）"
  type        = string
}

variable "handler" {
  description = "Lambda ハンドラ。<ファイル名>.<関数名> の形式で指定する。"
  type        = string
  default     = "handler.lambda_handler"
}

variable "source_dir" {
  description = "Lambda ソースコードのディレクトリパス（例: ../../../src/ingestor）。archive_file で zip 化する。"
  type        = string
}

variable "s3_bucket" {
  description = "Lambda zip パッケージをアップロードする S3 バケット名。デプロイアーティファクト専用バケットを指定する。"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名（dev / staging / prod）。IAM ロール命名に使用する。"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment は dev / staging / prod のいずれかを指定してください。"
  }
}

variable "project" {
  description = "プロジェクト識別子（デフォルト: sep）。リソース命名の prefix に使用する。"
  type        = string
  default     = "sep"
}

# ── オプションパラメータ（デフォルト値あり）────────────────────

variable "runtime" {
  description = "Lambda ランタイム。Powertools は python3.12 以上を推奨する。"
  type        = string
  default     = "python3.12"
}

variable "timeout" {
  description = "Lambda タイムアウト秒数。SQS 可視性タイムアウトはこの値の 6 倍に設定すること。"
  type        = number
  default     = 30

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout は 1〜900 秒の範囲で指定してください。"
  }
}

variable "memory_size" {
  description = "Lambda メモリサイズ（MB）。arm64 では 128〜10240 MB が指定可能。"
  type        = number
  default     = 256

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size は 128〜10240 MB の範囲で指定してください。"
  }
}

variable "environment_variables" {
  description = "Lambda 環境変数。POWERTOOLS_SERVICE_NAME・LOG_LEVEL は自動付与されるため指定不要。"
  type        = map(string)
  default     = {}
}

variable "log_level" {
  description = "Powertools ログレベル（DEBUG / INFO / WARNING / ERROR）"
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level は DEBUG / INFO / WARNING / ERROR のいずれかを指定してください。"
  }
}

variable "reserved_concurrent_executions" {
  description = "予約済み同時実行数。-1 はアカウントの未予約同時実行プールから使用する（制限なし）。0 は関数を無効化する。"
  type        = number
  default     = -1
}

variable "layers" {
  description = "追加 Lambda レイヤー ARN のリスト。Powertools レイヤーは SSM から自動取得されるため不要。"
  type        = list(string)
  default     = []
}

variable "additional_policy_arns" {
  description = "Lambda 実行ロールに追加アタッチする IAM ポリシー ARN のリスト。関数固有の権限（DynamoDB・SQS など）を指定する。"
  type        = list(string)
  default     = []
}

variable "powertools_ssm_parameter" {
  description = "Powertools Lambda レイヤー ARN を格納した SSM パラメータ名。bootstrap.sh で設定される。"
  type        = string
  # デフォルトは bootstrap.sh でパラメータを書き込む命名規則に従う
  default = ""
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持期間（日）。コスト管理のため本番でも 14 日を推奨。"
  type        = number
  default     = 14
}

variable "common_tags" {
  description = "リソースに付与する追加タグ。provider の default_tags で付与されるタグに上書きマージされる。"
  type        = map(string)
  default     = {}
}
