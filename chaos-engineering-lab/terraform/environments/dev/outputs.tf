output "vpc_id" {
  description = "VPC の ID（Phase 2 以降のモジュールに渡す）"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID のリスト（ALB 配置用）"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID のリスト（EC2/ASG 配置用）"
  value       = module.vpc.private_subnet_ids
}

output "alb_sg_id" {
  description = "ALB 用セキュリティグループの ID"
  value       = module.sg.alb_sg_id
}

output "ec2_sg_id" {
  description = "EC2 用セキュリティグループの ID"
  value       = module.sg.ec2_sg_id
}

# ── Phase 2: ALB + ASG ─────────────────────────────────────────────

output "alb_dns_name" {
  description = "ALB の DNS 名（curl での動作確認用）"
  value       = module.alb.alb_dns_name
}

output "target_group_arn" {
  description = "ALB ターゲットグループの ARN"
  value       = module.alb.target_group_arn
}

output "asg_name" {
  description = "Auto Scaling Group の名前（FIS ターゲット・Phase 3 で使用）"
  value       = module.asg.asg_name
}

output "asg_arn" {
  description = "Auto Scaling Group の ARN（FIS リソース ARN・Phase 3 で使用）"
  value       = module.asg.asg_arn
}

output "alb_arn" {
  description = "ALB の ARN（FIS 停止条件の監視対象・Phase 3 で使用）"
  value       = module.alb.alb_arn
}

# ── Phase 3: IAM + FIS ─────────────────────────────────────────────

output "fis_experiment_template_id" {
  description = "FIS 実験テンプレートの ID（run_experiment.sh に設定して使用）"
  value       = module.fis.experiment_template_id
}

output "fis_role_arn" {
  description = "FIS 実行ロールの ARN"
  value       = module.iam.fis_role_arn
}

output "stop_condition_alarm_arn" {
  description = "FIS 停止条件 CloudWatch アラームの ARN"
  value       = module.fis.stop_condition_alarm_arn
}
