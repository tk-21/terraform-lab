output "bedrock_iam_role_arn" {
  description = "ARN of the IAM role for Bedrock invocation"
  value       = aws_iam_role.bedrock_invoke.arn
}

output "bedrock_iam_role_name" {
  description = "Name of the IAM role for Bedrock invocation"
  value       = aws_iam_role.bedrock_invoke.name
}

output "guardrail_id" {
  description = "Bedrock Guardrail ID"
  value       = aws_bedrock_guardrail.main.guardrail_id
}

output "guardrail_arn" {
  description = "Bedrock Guardrail ARN"
  value       = aws_bedrock_guardrail.main.guardrail_arn
}

output "guardrail_version" {
  description = "Bedrock Guardrail version"
  value       = aws_bedrock_guardrail.main.version
}

output "cloudtrail_arn" {
  description = "ARN of the Bedrock CloudTrail"
  value       = aws_cloudtrail.bedrock.arn
}

output "cloudtrail_s3_bucket" {
  description = "S3 bucket name for CloudTrail logs"
  value       = aws_s3_bucket.cloudtrail.id
}

output "cloudtrail_log_group" {
  description = "CloudWatch Log Group for CloudTrail"
  value       = aws_cloudwatch_log_group.cloudtrail.name
}
