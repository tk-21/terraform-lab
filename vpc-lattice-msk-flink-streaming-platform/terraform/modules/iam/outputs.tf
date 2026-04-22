output "flink_role_arn" {
  description = "Flink execution role ARN"
  value       = aws_iam_role.flink.arn
}

output "flink_role_name" {
  description = "Flink execution role name"
  value       = aws_iam_role.flink.name
}

output "producer_role_arn" {
  description = "Lambda Producer role ARN"
  value       = aws_iam_role.producer.arn
}

output "producer_role_name" {
  description = "Lambda Producer role name"
  value       = aws_iam_role.producer.name
}

output "github_actions_role_arn" {
  description = "GitHub Actions role ARN"
  value       = aws_iam_role.github_actions.arn
}
