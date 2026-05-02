# ---------------------------------------------------------------------------
# Phase 1: Network outputs
# ---------------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (3要素, ALB 配置層)"
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (3要素, EC2 ASG 配置層)"
  value       = module.network.private_subnet_ids
}

output "data_subnet_ids" {
  description = "Data subnet IDs (3要素, RDS Aurora 配置層)"
  value       = module.network.data_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway のパブリック IP (送信元IP確認用)"
  value       = module.network.nat_gateway_public_ips
}

output "vpc_flow_log_group_name" {
  description = "VPC Flow Logs の CloudWatch Logs グループ名"
  value       = module.network.vpc_flow_log_group_name
}

# ---------------------------------------------------------------------------
# Phase 2: KMS / Secrets Manager outputs
# ---------------------------------------------------------------------------
output "kms_key_arn" {
  description = "KMS CMK ARN — Phase 3 で RDS 暗号化・ローテーション Lambda に使用"
  value       = aws_kms_key.main.arn
}

output "kms_key_id" {
  description = "KMS CMK Key ID"
  value       = aws_kms_key.main.key_id
}

output "rds_secret_arn" {
  description = "Secrets Manager secret ARN — Phase 3 で RDS 接続情報取得に使用"
  value       = aws_secretsmanager_secret.rds_master.arn
  sensitive   = true
}

output "rds_secret_name" {
  description = "Secrets Manager secret name"
  value       = aws_secretsmanager_secret.rds_master.name
}

# ---------------------------------------------------------------------------
# Phase 2: Security outputs
# ---------------------------------------------------------------------------
output "ec2_security_group_id" {
  description = "EC2 Security Group ID — Phase 3 で RDS SG のインバウンドルールに使用"
  value       = module.security.ec2_sg_id
}

output "rds_security_group_id" {
  description = "RDS Security Group ID — Phase 3 で RDS Aurora に割り当て"
  value       = module.security.rds_sg_id
}

output "ec2_instance_profile_name" {
  description = "EC2 IAM Instance Profile name"
  value       = module.security.ec2_instance_profile_name
}

output "session_logs_bucket_name" {
  description = "S3 bucket name for SSM Session Manager logs"
  value       = module.security.session_logs_bucket_name
}

# ---------------------------------------------------------------------------
# Phase 2: Compute outputs
# ---------------------------------------------------------------------------
output "alb_dns_name" {
  description = "ALB DNS name — 動作確認用"
  value       = module.compute.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID — Route 53 alias レコード作成時に使用"
  value       = module.compute.alb_zone_id
}

output "asg_name" {
  description = "Auto Scaling Group name — Phase 4 Ansible 動的インベントリフィルタリング用"
  value       = module.compute.asg_name
}

output "target_group_arn" {
  description = "ALB target group ARN"
  value       = module.compute.target_group_arn
}

# ---------------------------------------------------------------------------
# Phase 3: Database outputs
# ---------------------------------------------------------------------------
output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint (書き込み用)"
  value       = module.database.cluster_endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora cluster reader endpoint (読み取り用)"
  value       = module.database.reader_endpoint
}

output "aurora_cluster_identifier" {
  description = "Aurora cluster identifier"
  value       = module.database.cluster_identifier
}

# ---------------------------------------------------------------------------
# Phase 3: SSM outputs
# ---------------------------------------------------------------------------
output "ssm_session_log_group_name" {
  description = "SSM セッションログの CloudWatch Logs グループ名"
  value       = module.ssm.ssm_session_log_group_name
}

output "app_data_bucket_name" {
  description = "アプリデータ S3 バケット名 (静的コンテンツ用)"
  value       = module.compute.app_data_bucket_name
}

# ---------------------------------------------------------------------------
# Phase 3: 接続・運用コマンド
# ---------------------------------------------------------------------------
output "ssm_connect_command" {
  description = "SSM Session Manager 接続コマンド (<instance_id> を実際の ID に置き換えて使用)"
  value       = "aws ssm start-session --target <instance_id> --region ap-northeast-1"
}
