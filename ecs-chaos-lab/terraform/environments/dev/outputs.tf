output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID リスト"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト (ECS Task 配置先)"
  value       = module.vpc.private_subnet_ids
}

output "alb_sg_id" {
  description = "ALB セキュリティグループ ID"
  value       = module.sg.alb_sg_id
}

output "ecs_task_sg_id" {
  description = "ECS Task セキュリティグループ ID"
  value       = module.sg.ecs_task_sg_id
}

output "alb_dns_name" {
  description = "ALB DNS 名 (動作確認用 URL)"
  value       = module.alb.alb_dns_name
}

output "target_group_arn" {
  description = "ターゲットグループ ARN (Phase 2 ECS モジュールで使用)"
  value       = module.alb.target_group_arn
}

output "ecr_repository_url" {
  description = "ECR リポジトリ URL (bootstrap.sh でのイメージプッシュ先)"
  value       = module.ecr.repository_url
}

output "cluster_name" {
  description = "ECS クラスター名 (Phase 3 fis モジュールで使用)"
  value       = module.ecs.cluster_name
}

output "cluster_arn" {
  description = "ECS クラスター ARN (Phase 3 fis モジュールで使用)"
  value       = module.ecs.cluster_arn
}

output "service_name" {
  description = "ECS サービス名 (Phase 3 fis モジュールで使用)"
  value       = module.ecs.service_name
}

output "fis_role_arn" {
  description = "FIS 実行ロール ARN (Phase 3 fis モジュールで使用)"
  value       = module.iam.fis_role_arn
}

output "stop_condition_task_kill_arn" {
  description = "FIS 停止条件アラーム ARN（シナリオ1: Task Kill 用）"
  value       = module.ecs.stop_condition_alarm_task_kill_arn
}

output "stop_condition_network_arn" {
  description = "FIS 停止条件アラーム ARN（シナリオ2: Network Disruption 用）"
  value       = module.ecs.stop_condition_alarm_network_arn
}

output "scenario1_template_id" {
  description = "シナリオ1 (Task Kill) FIS 実験テンプレート ID (run_task_kill.sh で使用)"
  value       = module.fis.scenario1_template_id
}

output "scenario2_template_id" {
  description = "シナリオ2 (Network Disruption) FIS 実験テンプレート ID (run_network_disruption.sh で使用)"
  value       = module.fis.scenario2_template_id
}

output "scenario3_template_id" {
  description = "シナリオ3 (Desired Zero) FIS 実験テンプレート ID (run_desired_zero.sh で使用)"
  value       = module.fis.scenario3_template_id
}

output "lambda_function_name" {
  description = "シナリオ3用 Lambda 関数名 (run_desired_zero.sh の復旧コマンドで使用)"
  value       = module.fis.lambda_function_name
}
