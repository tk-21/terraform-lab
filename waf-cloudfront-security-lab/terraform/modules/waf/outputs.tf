output "webacl_arn" {
  description = "WAF WebACL ARN (CloudFront アタッチ用 / Phase 3 の Kinesis ログ配信先設定に使用)"
  value       = aws_wafv2_web_acl.main.arn
}

output "webacl_id" {
  description = "WAF WebACL ID"
  value       = aws_wafv2_web_acl.main.id
}

output "webacl_name" {
  description = "WAF WebACL 名"
  value       = aws_wafv2_web_acl.main.name
}
