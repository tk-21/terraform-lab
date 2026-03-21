output "athena_workgroup_name" {
  description = "Athena Workgroup name"
  value       = aws_athena_workgroup.this.name
}

output "athena_workgroup_arn" {
  description = "Athena Workgroup ARN"
  value       = aws_athena_workgroup.this.arn
}
