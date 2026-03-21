output "lambda_arn" {
  description = "Anomaly detector Lambda function ARN"
  value       = aws_lambda_function.anomaly_detector.arn
}

output "lambda_function_name" {
  description = "Anomaly detector Lambda function name"
  value       = aws_lambda_function.anomaly_detector.function_name
}

output "lambda_invoke_arn" {
  description = "Anomaly detector Lambda invoke ARN (for Step Functions)"
  value       = aws_lambda_function.anomaly_detector.invoke_arn
}

output "lambda_role_arn" {
  description = "Anomaly detector Lambda IAM role ARN"
  value       = aws_iam_role.anomaly_detector.arn
}
