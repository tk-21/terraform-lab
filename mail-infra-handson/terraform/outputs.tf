# ============================================================
# DNS
# ============================================================

output "name_servers" {
  description = "Route 53のNSレコード。ドメインレジストラ側のNS設定をこの値に更新すること"
  value       = module.dns.name_servers
}

output "hosted_zone_id" {
  description = "Route 53 Hosted Zone ID"
  value       = module.dns.hosted_zone_id
}

# ============================================================
# SES
# ============================================================

output "ses_verification_status" {
  description = "SESドメイン検証ステータス。SUCCESS になってから送信が可能になる"
  value       = module.ses_identity.verification_status
}

output "ses_configuration_set_name" {
  description = "SES Configuration Set名。メール送信時に ConfigurationSetName として指定する"
  value       = module.ses_config.configuration_set_name
}

output "ses_smtp_endpoint" {
  description = "SES SMTPエンドポイント。Postfixの relayhost に設定する値"
  value       = "email-smtp.${var.aws_region}.amazonaws.com"
}

# ============================================================
# 受信パイプライン
# ============================================================

output "inbound_bucket_name" {
  description = "受信メール保存用S3バケット名"
  value       = module.inbound_pipeline.s3_inbound_bucket_name
}

output "receipt_rule_set_name" {
  description = "SES Receipt Rule Set名"
  value       = module.inbound_pipeline.receipt_rule_set_name
}

# ============================================================
# 監視
# ============================================================

output "alarm_topic_arn" {
  description = "CloudWatchアラーム通知用SNSトピックのARN"
  value       = module.monitoring.alarm_topic_arn
}

output "dashboard_name" {
  description = "CloudWatchダッシュボード名"
  value       = module.monitoring.dashboard_name
}

# ============================================================
# VPC Endpoint
# ============================================================

output "vpc_endpoint_id" {
  description = "SES SMTP VPC Endpoint ID"
  value       = module.vpc_endpoint.endpoint_id
}
