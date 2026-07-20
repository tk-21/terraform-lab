output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト"
  value       = module.networking.private_subnet_ids
}

output "orders_queue_url" {
  description = "注文キュー URL"
  value       = module.sqs.orders_queue_url
}

output "orders_queue_arn" {
  description = "注文キュー ARN"
  value       = module.sqs.orders_queue_arn
}

output "orders_dlq_arn" {
  description = "注文 DLQ ARN"
  value       = module.sqs.orders_dlq_arn
}

output "dynamodb_table_name" {
  description = "DynamoDB テーブル名"
  value       = aws_dynamodb_table.orders.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB テーブル ARN"
  value       = aws_dynamodb_table.orders.arn
}

output "ecr_repository_url" {
  description = "ECR リポジトリ URL"
  value       = module.ecs.ecr_repository_url
}

output "ecs_cluster_name" {
  description = "ECS クラスター名"
  value       = module.ecs.ecs_cluster_name
}

output "ecs_cluster_arn" {
  description = "ECS クラスター ARN"
  value       = module.ecs.ecs_cluster_arn
}

output "task_definition_arn" {
  description = "ECS タスク定義 ARN"
  value       = module.ecs.task_definition_arn
}

output "ecs_task_sg_id" {
  description = "ECS タスク セキュリティグループ ID"
  value       = module.ecs.ecs_task_sg_id
}

output "state_machine_arn" {
  description = "Step Functions ステートマシン ARN"
  value       = module.step_functions.state_machine_arn
}

output "state_machine_name" {
  description = "Step Functions ステートマシン名"
  value       = module.step_functions.state_machine_name
}

output "sfn_trigger_function_name" {
  description = "SQS → Step Functions トリガー Lambda 名"
  value       = module.step_functions.sfn_trigger_function_name
}

output "orders_dlq_url" {
  description = "注文 DLQ URL"
  value       = module.sqs.orders_dlq_url
}

output "dashboard_url" {
  description = "CloudWatch ダッシュボード URL"
  value       = module.monitoring.dashboard_url
}
