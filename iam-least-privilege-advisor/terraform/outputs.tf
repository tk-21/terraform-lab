# -----------------------------------------------------------------------
# S3 出力
# -----------------------------------------------------------------------
output "results_bucket_name" {
  description = "Analyzer 結果保存 S3 バケット名"
  value       = module.s3.bucket_name
}

output "results_bucket_arn" {
  description = "Analyzer 結果保存 S3 バケットの ARN"
  value       = module.s3.bucket_arn
}

# -----------------------------------------------------------------------
# IAM 出力
# -----------------------------------------------------------------------
output "analyzer_trigger_role_arn" {
  description = "analyzer-trigger Lambda 実行ロールの ARN"
  value       = module.iam.analyzer_trigger_role_arn
}

output "policy_advisor_role_arn" {
  description = "policy-advisor Lambda 実行ロールの ARN"
  value       = module.iam.policy_advisor_role_arn
}

# -----------------------------------------------------------------------
# Lambda 出力
# -----------------------------------------------------------------------
output "analyzer_trigger_function_arn" {
  description = "analyzer-trigger Lambda 関数の ARN"
  value       = module.lambda.analyzer_trigger_function_arn
}

output "analyzer_trigger_function_name" {
  description = "analyzer-trigger Lambda 関数の名前"
  value       = module.lambda.analyzer_trigger_function_name
}

output "policy_advisor_function_arn" {
  description = "policy-advisor Lambda 関数の ARN"
  value       = module.lambda.policy_advisor_function_arn
}

output "policy_advisor_function_name" {
  description = "policy-advisor Lambda 関数の名前"
  value       = module.lambda.policy_advisor_function_name
}

# -----------------------------------------------------------------------
# Access Analyzer 出力
# -----------------------------------------------------------------------
output "unused_access_analyzer_arn" {
  description = "未使用アクセス検出 Analyzer の ARN"
  value       = module.access_analyzer.unused_access_analyzer_arn
}

output "external_access_analyzer_arn" {
  description = "外部アクセス検出 Analyzer の ARN"
  value       = module.access_analyzer.external_access_analyzer_arn
}

# -----------------------------------------------------------------------
# EventBridge 出力
# -----------------------------------------------------------------------
output "scheduler_arn" {
  description = "EventBridge Scheduler の ARN"
  value       = module.eventbridge.scheduler_arn
}

output "scheduler_role_arn" {
  description = "EventBridge Scheduler 用 IAM ロールの ARN"
  value       = module.eventbridge.scheduler_role_arn
}
