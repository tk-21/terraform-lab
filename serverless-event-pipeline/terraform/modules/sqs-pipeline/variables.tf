# sqs-pipeline モジュールの変数定義
# S3 PUT → SQS キュー → Lambda ESM の構成に必要なパラメータを定義する。

# ── 必須パラメータ ────────────────────────────────────────────

variable "project" {
  description = "プロジェクト識別子（例: sep）。リソース命名の prefix に使用する。"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名（dev / staging / prod）"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment は dev / staging / prod のいずれかを指定してください。"
  }
}

variable "account_id" {
  description = "AWS アカウント ID。S3 バケット名のグローバル一意性確保および SQS ポリシーの SourceAccount 条件に使用する。"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id は 12 桁の数字で指定してください。"
  }
}

variable "pipeline_name" {
  description = "パイプライン識別名（例: ingest）。SQS キュー名・DLQ 名・S3 バケット名の一部に使用する。"
  type        = string
}

variable "lambda_alias_arn" {
  description = "ESM（イベントソースマッピング）のトリガー先 Lambda エイリアス ARN。lambda-function モジュールの alias_arn を渡す。"
  type        = string
}

# ── オプションパラメータ ──────────────────────────────────────

variable "lambda_timeout" {
  description = "Lambda タイムアウト秒数。SQS 可視性タイムアウトはこの値の 6 倍に設定される。"
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "カスタマーマネージド KMS キー ARN。空文字の場合は SQS マネージド SSE（SQS）と AWS マネージドキー（S3）を使用する。"
  type        = string
  default     = ""
}

variable "batch_size" {
  description = "Lambda ESM のバッチサイズ。1 回の Lambda 呼び出しで処理する最大 SQS メッセージ数。"
  type        = number
  default     = 10

  validation {
    condition     = var.batch_size >= 1 && var.batch_size <= 10000
    error_message = "batch_size は 1〜10000 の範囲で指定してください。"
  }
}

variable "dlq_max_receive_count" {
  description = "DLQ へ移動するまでの最大受信試行回数。この回数を超えたメッセージは DLQ へ転送される。"
  type        = number
  default     = 3
}

variable "message_retention_seconds" {
  description = "SQS メッセージ保持期間（秒）。デフォルト 345600 秒（4 日）。"
  type        = number
  default     = 345600 # 4日
}

variable "notification_filter_prefix" {
  description = "S3 PUT イベント通知のプレフィックスフィルター。空文字はフィルターなし（全オブジェクト対象）。"
  type        = string
  default     = ""
}

variable "notification_filter_suffix" {
  description = "S3 PUT イベント通知のサフィックスフィルター（例: .json）。空文字はフィルターなし。"
  type        = string
  default     = ""
}

variable "alarm_action_arns" {
  description = "DLQ メッセージ数アラーム発火時の通知先 SNS トピック ARN リスト。"
  type        = list(string)
  default     = []
}

variable "common_tags" {
  description = "全リソースに付与する追加タグ。provider の default_tags にマージされる。"
  type        = map(string)
  default     = {}
}
