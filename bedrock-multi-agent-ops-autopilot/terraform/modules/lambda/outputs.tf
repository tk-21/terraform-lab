output "incident_investigator_function_arn" {
  description = "incident_investigator Lambda ARN"
  value       = aws_lambda_function.incident_investigator.arn
}

output "incident_investigator_function_name" {
  description = "incident_investigator Lambda 関数名"
  value       = aws_lambda_function.incident_investigator.function_name
}

output "cost_optimizer_function_arn" {
  description = "cost_optimizer Lambda ARN"
  value       = aws_lambda_function.cost_optimizer.arn
}

output "cost_optimizer_function_name" {
  description = "cost_optimizer Lambda 関数名"
  value       = aws_lambda_function.cost_optimizer.function_name
}

output "remediation_function_arn" {
  description = "remediation Lambda ARN"
  value       = aws_lambda_function.remediation.arn
}

output "remediation_function_name" {
  description = "remediation Lambda 関数名"
  value       = aws_lambda_function.remediation.function_name
}

output "reporter_function_arn" {
  description = "reporter Lambda ARN"
  value       = aws_lambda_function.reporter.arn
}

output "reporter_function_name" {
  description = "reporter Lambda 関数名"
  value       = aws_lambda_function.reporter.function_name
}
