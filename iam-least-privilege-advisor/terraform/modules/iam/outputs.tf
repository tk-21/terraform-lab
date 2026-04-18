output "analyzer_trigger_role_arn" {
  description = "analyzer-trigger Lambda 実行ロールの ARN"
  value       = aws_iam_role.analyzer_trigger.arn
}

output "analyzer_trigger_role_name" {
  description = "analyzer-trigger Lambda 実行ロールの名前"
  value       = aws_iam_role.analyzer_trigger.name
}

output "policy_advisor_role_arn" {
  description = "policy-advisor Lambda 実行ロールの ARN"
  value       = aws_iam_role.policy_advisor.arn
}

output "policy_advisor_role_name" {
  description = "policy-advisor Lambda 実行ロールの名前"
  value       = aws_iam_role.policy_advisor.name
}
