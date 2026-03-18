output "alert_topic_arn" {
  description = "SNS topic ARN for budget alerts"
  value       = aws_sns_topic.budget_alerts.arn
}

output "alert_topic_name" {
  description = "SNS topic name for budget alerts"
  value       = aws_sns_topic.budget_alerts.name
}

output "lambda_function_name" {
  description = "Cost controller Lambda function name"
  value       = aws_lambda_function.cost_controller.function_name
}

output "lambda_function_arn" {
  description = "Cost controller Lambda function ARN"
  value       = aws_lambda_function.cost_controller.arn
}

output "budget_name" {
  description = "AWS Budgets budget name"
  value       = aws_budgets_budget.monthly.name
}
