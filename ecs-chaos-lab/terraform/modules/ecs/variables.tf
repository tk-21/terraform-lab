variable "prefix" {
  description = "リソース名プレフィックス (例: ecl)"
  type        = string
}

variable "env" {
  description = "環境名 (例: dev, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "task_cpu" {
  description = "ECS タスク CPU ユニット (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "ECS タスクメモリ (MB)"
  type        = number
  default     = 512
}

variable "container_port" {
  description = "コンテナが Listen するポート番号"
  type        = number
  default     = 80
}

variable "desired_count" {
  description = "ECS サービスの希望タスク数"
  type        = number
  default     = 2
}

variable "ecr_image_uri" {
  description = "ECR イメージ URI (bootstrap.sh 実行後に有効化)"
  type        = string
}

variable "task_execution_role_arn" {
  description = "ECS Task 実行ロール ARN (iam モジュールから渡す)"
  type        = string
}

variable "task_role_arn" {
  description = "ECS Task ロール ARN (iam モジュールから渡す)"
  type        = string
}

variable "private_subnet_ids" {
  description = "ECS Task を配置するプライベートサブネット ID リスト"
  type        = list(string)
}

variable "ecs_task_sg_id" {
  description = "ECS Task セキュリティグループ ID (sg モジュールから渡す)"
  type        = string
}

variable "target_group_arn" {
  description = "ALB ターゲットグループ ARN (alb モジュールから渡す)"
  type        = string
}

variable "target_group_arn_suffix" {
  description = "ALB ターゲットグループ ARN サフィックス (CW アラームの dimensions に使用)"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN サフィックス (CW アラームの dimensions に使用)"
  type        = string
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
