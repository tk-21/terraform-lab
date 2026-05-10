output "asg_name" {
  description = "Auto Scaling Group の名前（FIS ターゲットとして使用）"
  value       = aws_autoscaling_group.main.name
}

output "asg_arn" {
  description = "Auto Scaling Group の ARN（FIS リソース ARN として使用）"
  value       = aws_autoscaling_group.main.arn
}

output "launch_template_id" {
  description = "Launch Template の ID"
  value       = aws_launch_template.main.id
}
