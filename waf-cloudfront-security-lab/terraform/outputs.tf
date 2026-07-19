output "alb_dns_name" {
  description = "ALB の DNS 名 (CloudFront オリジン設定に使用)"
  value       = module.origin.alb_dns_name
}

output "alb_arn" {
  description = "ALB の ARN (Phase 2 の WAF WebACL アタッチ先)"
  value       = module.origin.alb_arn
}

output "vpc_id" {
  description = "VPC ID (Phase 3 の Kinesis サブネット指定に使用)"
  value       = module.origin.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト"
  value       = module.origin.private_subnet_ids
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID リスト"
  value       = module.origin.public_subnet_ids
}

output "ecs_cluster_arn" {
  description = "ECS クラスターの ARN"
  value       = module.origin.ecs_cluster_arn
}

output "alb_security_group_id" {
  description = "ALB セキュリティグループ ID (Phase 2 で CloudFront IP 制限に更新)"
  value       = module.origin.alb_security_group_id
}

# Phase 2 追加 ---

output "webacl_arn" {
  description = "WAF WebACL ARN (Phase 3 の Kinesis Firehose ログ配信先設定に使用)"
  value       = module.waf.webacl_arn
}

output "webacl_id" {
  description = "WAF WebACL ID"
  value       = module.waf.webacl_id
}

output "cloudfront_domain_name" {
  description = "CloudFront ディストリビューションのドメイン名 (Phase 5 の攻撃シミュレーションで使用)"
  value       = module.cloudfront.cloudfront_domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront ディストリビューション ID (Phase 4 の Lambda@Edge アタッチ先)"
  value       = module.cloudfront.cloudfront_distribution_id
}

# Phase 4 追加 ---

output "alert_alarm_name" {
  description = "WAF ブロック数 CloudWatch アラーム名 (Phase 5 の動作確認で状態確認に使用)"
  value       = module.alert.alarm_name
}

output "alert_lambda_function_name" {
  description = "alert_notifier Lambda 関数名 (ログ確認・テスト実行に使用)"
  value       = module.alert.lambda_function_name
}

output "alert_eventbridge_rule_name" {
  description = "EventBridge ルール名"
  value       = module.alert.eventbridge_rule_name
}

# Phase 3 追加 ---

output "waf_logs_bucket_name" {
  description = "WAF ログ S3 バケット名 (Phase 4 のアラート通知補足情報として使用)"
  value       = module.waf_logs.waf_logs_bucket_name
}

output "athena_workgroup_name" {
  description = "Athena ワークグループ名 (クエリ実行時に指定)"
  value       = module.waf_logs.athena_workgroup_name
}

output "athena_database_name" {
  description = "Athena データベース名"
  value       = module.waf_logs.athena_database_name
}
