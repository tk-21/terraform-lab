# =============================================================================
# Step Functionsモジュール 変数定義
# =============================================================================

variable "project" {
  description = "プロジェクト名（全リソースの命名プレフィックスに使用）"
  type        = string
}

variable "environment" {
  description = "環境名（dev / stg / prod）"
  type        = string
}

variable "region" {
  description = "デプロイ先AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_account_id" {
  description = "AWSアカウントID（IAMポリシーのARN組み立てに使用）"
  type        = string
}

variable "data_collector_arn" {
  description = "data-collector Lambda関数のARN（CollectDataステート）"
  type        = string
}

variable "bedrock_analyzer_arn" {
  description = "bedrock-analyzer Lambda関数のARN（AnalyzeWithBedrockステート）"
  type        = string
}

variable "report_formatter_arn" {
  description = "report-formatter Lambda関数のARN（FormatReportステート）"
  type        = string
}

variable "notifier_arn" {
  description = "notifier Lambda関数のARN（Notify / ErrorNotifyステート）"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
}
