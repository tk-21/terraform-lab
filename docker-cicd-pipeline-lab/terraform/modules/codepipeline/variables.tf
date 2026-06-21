variable "name_prefix" {
  description = "リソース命名プレフィックス"
  type        = string
}

variable "account_id" {
  description = "AWS アカウント ID"
  type        = string
}

variable "github_connection_arn" {
  description = "CodeStar Connections の GitHub Connection ARN"
  type        = string
}

variable "github_owner" {
  description = "GitHub リポジトリオーナー名"
  type        = string
}

variable "github_repo" {
  description = "GitHub リポジトリ名"
  type        = string
}

variable "github_branch" {
  description = "監視するブランチ名"
  type        = string
}

variable "codebuild_project_name" {
  description = "CodeBuild プロジェクト名"
  type        = string
}

variable "codebuild_project_arn" {
  description = "CodeBuild プロジェクト ARN (IAM ポリシーのスコープ限定用)"
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS クラスター名"
  type        = string
}

variable "ecs_service_name" {
  description = "ECS サービス名"
  type        = string
}

variable "listener_http_arn" {
  description = "ALB 本番トラフィック (HTTP:80) リスナー ARN"
  type        = string
}

variable "listener_test_arn" {
  description = "ALB テストトラフィック (HTTP:8080) リスナー ARN"
  type        = string
}

variable "tg_blue_name" {
  description = "Blue ターゲットグループ名"
  type        = string
}

variable "tg_green_name" {
  description = "Green ターゲットグループ名"
  type        = string
}

variable "task_execution_role_arn" {
  description = "ECS タスク実行ロール ARN (IAM PassRole のスコープ限定用)"
  type        = string
}

variable "task_role_arn" {
  description = "ECS タスクロール ARN (IAM PassRole のスコープ限定用)"
  type        = string
}

variable "artifact_bucket_arn" {
  description = "CodePipeline アーティファクト S3 バケット ARN (IAM ポリシーのスコープ用)"
  type        = string
}

variable "artifact_bucket_id" {
  description = "CodePipeline アーティファクト S3 バケット ID (artifact_store の location に使用)"
  type        = string
}
