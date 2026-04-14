# kinesis-pipeline モジュールの変数定義
# Kinesis Data Streams + Lambda ESM + DLQ + CloudWatch Alarm の構成に必要なパラメータ。

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

variable "lambda_alias_arn" {
  description = "ESM（イベントソースマッピング）のトリガー先 Lambda エイリアス ARN。lambda-function モジュールの alias_arn を渡す。"
  type        = string
}

variable "lambda_role_name" {
  description = "Kinesis / DynamoDB 権限を付与する Lambda 実行ロール名。lambda-function モジュールの role_name を渡す。"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "BatchWriteItem の書き込み先 DynamoDB テーブル ARN。sep-<env>-events テーブルの ARN を指定する。"
  type        = string
}

# ── Kinesis ストリーム設定 ─────────────────────────────────────

variable "shard_count" {
  description = "Kinesis シャード数。dev は 1、prod は 2 を推奨（コスト管理 CLAUDE.md 参照）。"
  type        = number
  default     = 1

  validation {
    condition     = var.shard_count >= 1 && var.shard_count <= 100
    error_message = "shard_count は 1〜100 の範囲で指定してください。"
  }
}

variable "retention_hours" {
  description = "Kinesis レコード保持期間（時間）。dev は 24 時間、prod は 168 時間（7 日）。"
  type        = number
  default     = 24

  validation {
    condition     = contains([24, 48, 72, 168, 720, 8760], var.retention_hours)
    error_message = "retention_hours は 24 / 48 / 72 / 168 / 720 / 8760 のいずれかを指定してください。"
  }
}

# ── ESM（イベントソースマッピング）設定 ──────────────────────

variable "batch_size" {
  description = "1 回の Lambda 呼び出しで処理する最大 Kinesis レコード数。最大 10000。"
  type        = number
  default     = 100

  validation {
    condition     = var.batch_size >= 1 && var.batch_size <= 10000
    error_message = "batch_size は 1〜10000 の範囲で指定してください。"
  }
}

variable "maximum_batching_window_in_seconds" {
  description = "Lambda を起動する前にレコードを蓄積する最大待機時間（秒）。バッチを大きくしてスループットを最適化する。"
  type        = number
  default     = 5

  validation {
    condition     = var.maximum_batching_window_in_seconds >= 0 && var.maximum_batching_window_in_seconds <= 300
    error_message = "maximum_batching_window_in_seconds は 0〜300 の範囲で指定してください。"
  }
}

variable "maximum_retry_attempts" {
  description = "Lambda 呼び出しが失敗した場合の最大リトライ回数。-1 は無制限。0 は再試行なし。"
  type        = number
  default     = 3

  validation {
    condition     = var.maximum_retry_attempts >= -1 && var.maximum_retry_attempts <= 10000
    error_message = "maximum_retry_attempts は -1〜10000 の範囲で指定してください。"
  }
}

# ── CloudWatch アラーム設定 ───────────────────────────────────

variable "iterator_age_threshold_ms" {
  description = "IteratorAgeMilliseconds の警告閾値（ミリ秒）。この値を超えると Lambda の処理遅延アラームが発火する。"
  type        = number
  default     = 60000 # 60秒
}

variable "alarm_action_arns" {
  description = "アラーム発火時の通知先 SNS トピック ARN リスト。"
  type        = list(string)
  default     = []
}

# ── 共通設定 ──────────────────────────────────────────────────

variable "common_tags" {
  description = "全リソースに付与する追加タグ。provider の default_tags にマージされる。"
  type        = map(string)
  default     = {}
}
