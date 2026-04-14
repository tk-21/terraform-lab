# observability モジュールの変数定義
# X-Ray グループ・サンプリングルール・CloudWatch ダッシュボード・アラーム・
# Log Insights クエリ・Lambda Insights の全設定を受け取る変数をここで定義する。

variable "environment" {
  description = "デプロイ環境名（dev / staging / prod）"
  type        = string
}

variable "project" {
  description = "プロジェクト識別子。リソース命名の prefix に使用する。"
  type        = string
}

variable "sns_topic_arn" {
  description = "CloudWatch アラーム通知先の SNS トピック ARN。全アラームの alarm_actions・ok_actions に設定する。"
  type        = string
}

variable "lambda_function_names" {
  description = <<-EOT
    監視対象の Lambda 関数名リスト。
    ダッシュボードのメトリクスウィジェット・スロットルアラーム・コールドスタートアラームで使用する。
    例: ["sep-dev-ingestor", "sep-dev-transformer", "sep-dev-aggregator", "sep-dev-dlq-handler"]
  EOT
  type        = list(string)
}

variable "lambda_role_names" {
  description = <<-EOT
    Lambda Insights IAM ポリシーをアタッチする Lambda 実行ロール名リスト。
    CloudWatchLambdaInsightsExecutionRolePolicy を for_each で全ロールにアタッチする。
    例: ["sep-dev-ingestor-role", "sep-dev-transformer-role"]
  EOT
  type        = list(string)
}

variable "ingest_dlq_arn" {
  description = <<-EOT
    ingest パイプライン（SQS → Lambda ESM）の DLQ ARN。
    DLQ 滞留アラームおよびダッシュボードで使用する。
    キュー名は ARN（arn:aws:sqs:region:account:name）の末尾から自動抽出する。
  EOT
  type        = string
}

variable "transform_dlq_arn" {
  description = <<-EOT
    transform パイプライン（Kinesis ESM 失敗送信先）の DLQ ARN。
    DLQ 滞留アラームおよびダッシュボードで使用する。
    キュー名は ARN の末尾から自動抽出する。
  EOT
  type        = string
}

variable "kinesis_stream_name" {
  description = "Kinesis Data Streams のストリーム名。イテレータエイジアラームおよびダッシュボードで使用する。"
  type        = string
}

variable "log_group_names" {
  description = <<-EOT
    Log Insights クエリのデフォルト対象ロググループ名リスト。
    全 Lambda 関数のロググループ（/aws/lambda/<function_name>）を指定する。
    保存済みクエリの実行時にこれらのグループがデフォルト選択される。
  EOT
  type        = list(string)
}

variable "x_ray_sampling_rate" {
  description = <<-EOT
    X-Ray サンプリングレート（%）。
    本番: 10（コスト最適化: 100万トレースあたり課金のため）
    開発: 100（全トレース記録で問題追跡を容易にする）
    内部で 100 除算して fixed_rate（0.0〜1.0）に変換する。
  EOT
  type    = number
  default = 100

  validation {
    condition     = var.x_ray_sampling_rate >= 1 && var.x_ray_sampling_rate <= 100
    error_message = "x_ray_sampling_rate は 1 〜 100 の範囲で指定してください。"
  }
}

variable "common_tags" {
  description = "全リソースに付与する共通タグ（Project・ManagedBy・Environment・Owner）。"
  type        = map(string)
}
