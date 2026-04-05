variable "project_name" {
  description = "プロジェクト名（リソース名プレフィックスに使用）"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名（dev / stg / prd）"
  type        = string
}

variable "state_machine_name" {
  description = "監視対象の Step Functions ステートマシン名"
  type        = string
}

variable "workflow_starter_function_name" {
  description = "監視対象の workflow-starter Lambda 関数名"
  type        = string
}

variable "supervisor_function_name" {
  description = "監視対象の supervisor Lambda 関数名"
  type        = string
}

variable "alarm_email" {
  description = <<-EOT
    アラーム通知の送信先メールアドレス（任意）。
    未設定（空文字列）の場合は SNS サブスクリプションを作成しない。
  EOT
  type    = string
  default = ""
}
