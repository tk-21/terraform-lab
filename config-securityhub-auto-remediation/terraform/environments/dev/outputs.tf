output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "LambdaデプロイターゲットのプライベートサブネットIDリスト"
  value       = module.networking.private_subnet_ids
}

output "lambda_security_group_id" {
  description = "Lambda用セキュリティグループID"
  value       = module.networking.lambda_security_group_id
}

output "audit_bucket_name" {
  description = "S3監査ログバケット名"
  value       = module.audit.audit_bucket_name
}

output "dynamodb_table_name" {
  description = "DynamoDB修復ログテーブル名"
  value       = module.audit.dynamodb_table_name
}

output "dlq_arn" {
  description = "SQS DLQ ARN"
  value       = module.audit.dlq_arn
}

output "dlq_url" {
  description = "SQS DLQ URL"
  value       = module.audit.dlq_url
}

output "lambda_remediation_role_arn" {
  description = "Lambda修復実行ロールのARN (後続フェーズで使用)"
  value       = module.iam.lambda_remediation_role_arn
}

output "config_service_role_arn" {
  description = "Configサービスロール ARN"
  value       = module.iam.config_service_role_arn
}

output "eventbridge_invoke_role_arn" {
  description = "EventBridgeターゲット実行ロールのARN"
  value       = module.iam.eventbridge_invoke_role_arn
}

output "config_recorder_name" {
  description = "Config Recorder名"
  value       = module.config.config_recorder_name
}

output "config_rules" {
  description = "全Config Rule名のマップ"
  value       = module.config.config_rules
}

output "securityhub_hub_arn" {
  description = "Security Hub ARN"
  value       = module.security_hub.securityhub_hub_arn
}

output "securityhub_custom_action_arns" {
  description = "Security Hub Custom Action ARNのマップ (EventBridgeルール確認用)"
  value = {
    s3  = module.security_hub.s3_custom_action_arn
    iam = module.security_hub.iam_custom_action_arn
    sg  = module.security_hub.sg_custom_action_arn
    rds = module.security_hub.rds_custom_action_arn
  }
}

output "securityhub_findings_log_group" {
  description = "Security Hub Findings記録用CloudWatch Logsグループ名"
  value       = module.security_hub.findings_log_group_name
}

output "dashboard_arn" {
  description = "CloudWatch Dashboard ARN"
  value       = module.dashboard.dashboard_arn
}

output "alerts_sns_topic_arn" {
  description = "アラート通知用SNS Topic ARN"
  value       = module.dashboard.sns_topic_arn
}
