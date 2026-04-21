output "firehose_role_arn" {
  description = "ARN of the Firehose IAM role"
  value       = aws_iam_role.firehose.arn
}

output "lambda_receiver_role_arn" {
  description = "ARN of the Lambda Receiver IAM role"
  value       = aws_iam_role.lambda_receiver.arn
}

output "lambda_generator_role_arn" {
  description = "ARN of the Lambda Generator IAM role"
  value       = aws_iam_role.lambda_generator.arn
}

output "databrew_role_arn" {
  description = "ARN of the DataBrew IAM role"
  value       = aws_iam_role.databrew.arn
}

output "scheduler_role_arn" {
  description = "ARN of the EventBridge Scheduler IAM role"
  value       = aws_iam_role.scheduler.arn
}

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions IAM role"
  value       = aws_iam_role.github_actions.arn
}
