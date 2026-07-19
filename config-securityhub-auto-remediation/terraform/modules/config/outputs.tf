output "s3_noncompliant_rule_name" {
  description = "S3非準拠EventBridgeルール名"
  value       = aws_cloudwatch_event_rule.s3_noncompliant.name
}

output "iam_noncompliant_rule_name" {
  description = "IAM非準拠EventBridgeルール名"
  value       = aws_cloudwatch_event_rule.iam_noncompliant.name
}

output "sg_noncompliant_rule_name" {
  description = "SG非準拠EventBridgeルール名"
  value       = aws_cloudwatch_event_rule.sg_noncompliant.name
}

output "rds_noncompliant_rule_name" {
  description = "RDS非準拠EventBridgeルール名"
  value       = aws_cloudwatch_event_rule.rds_noncompliant.name
}

# Lambda permission の source_arn に使用するARN
output "s3_noncompliant_rule_arn" {
  description = "S3非準拠EventBridgeルールARN (Lambda permissionで使用)"
  value       = aws_cloudwatch_event_rule.s3_noncompliant.arn
}

output "iam_noncompliant_rule_arn" {
  description = "IAM非準拠EventBridgeルールARN"
  value       = aws_cloudwatch_event_rule.iam_noncompliant.arn
}

output "sg_noncompliant_rule_arn" {
  description = "SG非準拠EventBridgeルールARN"
  value       = aws_cloudwatch_event_rule.sg_noncompliant.arn
}

output "rds_noncompliant_rule_arn" {
  description = "RDS非準拠EventBridgeルールARN"
  value       = aws_cloudwatch_event_rule.rds_noncompliant.arn
}

output "config_rules" {
  description = "全Config Rule名のマップ (後続フェーズ参照用)"
  value = {
    s3_public  = aws_config_config_rule.s3_public_read_prohibited.name
    s3_sse     = aws_config_config_rule.s3_bucket_sse_enabled.name
    iam_mfa    = aws_config_config_rule.iam_user_mfa_enabled.name
    iam_policy = aws_config_config_rule.iam_no_inline_policy.name
    ssh        = aws_config_config_rule.restricted_ssh.name
    rdp        = aws_config_config_rule.restricted_rdp.name
    rds_enc    = aws_config_config_rule.rds_storage_encrypted.name
    rds_pub    = aws_config_config_rule.rds_public_access_check.name
  }
}

output "config_recorder_name" {
  description = "Config Recorder名"
  value       = aws_config_configuration_recorder.main.name
}
