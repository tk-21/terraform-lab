output "aws_inspector_lambda_arn" {
  description = "ARN of aws_inspector Lambda function"
  value       = aws_lambda_function.aws_inspector.arn
}

output "report_writer_lambda_arn" {
  description = "ARN of report_writer Lambda function"
  value       = aws_lambda_function.report_writer.arn
}

output "notifier_lambda_arn" {
  description = "ARN of notifier Lambda function"
  value       = aws_lambda_function.notifier.arn
}
