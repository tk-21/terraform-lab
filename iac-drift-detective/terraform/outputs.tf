# ドリフトレポート保存用S3バケット名
output "reports_bucket_name" {
  description = "ドリフトレポート保存用S3バケット名"
  value       = aws_s3_bucket.reports.id
}

# drift-detector Lambda実行ロールARN
output "detector_role_arn" {
  description = "drift-detector Lambda実行ロールARN"
  value       = aws_iam_role.detector.arn
}

# bedrock-analyzer Lambda実行ロールARN
output "analyzer_role_arn" {
  description = "bedrock-analyzer Lambda実行ロールARN"
  value       = aws_iam_role.analyzer.arn
}

# pr-creator Lambda実行ロールARN
output "pr_creator_role_arn" {
  description = "pr-creator Lambda実行ロールARN"
  value       = aws_iam_role.pr_creator.arn
}

# Step Functions実行ロールARN
output "sfn_role_arn" {
  description = "Step Functions実行ロールARN"
  value       = aws_iam_role.sfn.arn
}

# EventBridgeスケジュールルールARN
output "eventbridge_rule_arn" {
  description = "EventBridgeスケジュールルールARN"
  value       = aws_cloudwatch_event_rule.schedule.arn
}

# Step Functions State Machine ARN
output "state_machine_arn" {
  description = "Step Functions State MachineのARN"
  value       = module.step_functions.state_machine_arn
}

# drift-detector Lambda関数名
output "drift_detector_function_name" {
  description = "drift-detector Lambda関数名"
  value       = module.drift_detector.function_name
}

# bedrock-analyzer Lambda関数名
output "bedrock_analyzer_function_name" {
  description = "bedrock-analyzer Lambda関数名"
  value       = module.bedrock_analyzer.function_name
}

# pr-creator Lambda関数名
output "pr_creator_function_name" {
  description = "pr-creator Lambda関数名"
  value       = module.pr_creator.function_name
}
