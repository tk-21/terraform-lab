variable "name_prefix" {
  description = "リソース名プレフィックス (例: cicd-lab-prod)"
  type        = string
}

variable "ecs_cluster_name" {
  description = "監視対象の ECS クラスター名"
  type        = string
}

variable "ecs_service_name" {
  description = "監視対象の ECS サービス名"
  type        = string
}

variable "alb_arn_suffix" {
  description = "CloudWatch メトリクスのディメンジョンに使用する ALB ARN サフィックス"
  type        = string
}

variable "codebuild_project_name" {
  description = "ビルド時間を監視する CodeBuild プロジェクト名"
  type        = string
}

variable "pipeline_name" {
  description = "失敗検知対象の CodePipeline パイプライン名"
  type        = string
}

variable "sns_topic_arn" {
  description = "アラーム通知先の SNS トピック ARN (空文字列の場合はアクションなし)"
  type        = string
  default     = ""
}
