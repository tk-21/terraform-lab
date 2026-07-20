variable "project" {
  description = "プロジェクト名"
  type        = string
}

variable "common_tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
}

variable "state_machine_arn" {
  description = "Step Functions ステートマシン ARN"
  type        = string
}

variable "state_machine_name" {
  description = "Step Functions ステートマシン名"
  type        = string
}

variable "inventory_check_function" {
  description = "在庫確認 Lambda 関数名"
  type        = string
}

variable "notification_function" {
  description = "通知送信 Lambda 関数名"
  type        = string
}

variable "dlq_reprocessor_function" {
  description = "DLQ 補償処理 Lambda 関数名"
  type        = string
}

variable "sfn_trigger_function" {
  description = "SQS → Step Functions トリガー Lambda 関数名"
  type        = string
}

variable "orders_queue_name" {
  description = "注文 SQS キュー名"
  type        = string
}

variable "orders_dlq_name" {
  description = "注文 DLQ 名"
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS クラスター名"
  type        = string
}

variable "dynamodb_table_name" {
  description = "DynamoDB テーブル名"
  type        = string
}
