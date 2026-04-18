output "analyzer_trigger_function_arn" {
  description = "analyzer-trigger Lambda 関数の ARN"
  value       = aws_lambda_function.analyzer_trigger.arn
}

output "analyzer_trigger_function_name" {
  description = "analyzer-trigger Lambda 関数の名前"
  value       = aws_lambda_function.analyzer_trigger.function_name
}

output "policy_advisor_function_arn" {
  description = "policy-advisor Lambda 関数の ARN"
  value       = aws_lambda_function.policy_advisor.arn
}

output "policy_advisor_function_name" {
  description = "policy-advisor Lambda 関数の名前"
  value       = aws_lambda_function.policy_advisor.function_name
}
