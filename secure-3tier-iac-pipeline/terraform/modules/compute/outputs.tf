output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "ALB DNS name — 動作確認用"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID — Route 53 alias レコード作成時に使用"
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "ALB target group ARN"
  value       = aws_lb_target_group.web.arn
}

output "target_group_name" {
  description = "ALB target group name"
  value       = aws_lb_target_group.web.name
}

output "asg_name" {
  description = "Auto Scaling Group name — Ansible 動的インベントリフィルタリング用"
  value       = aws_autoscaling_group.web.name
}

output "asg_arn" {
  description = "Auto Scaling Group ARN"
  value       = aws_autoscaling_group.web.arn
}

output "launch_template_id" {
  description = "Launch Template ID"
  value       = aws_launch_template.web.id
}

output "launch_template_latest_version" {
  description = "Launch Template latest version number"
  value       = aws_launch_template.web.latest_version
}

output "alb_logs_bucket_name" {
  description = "S3 bucket name for ALB access logs"
  value       = aws_s3_bucket.alb_logs.bucket
}

output "app_data_bucket_name" {
  description = "S3 bucket name for app static content"
  value       = aws_s3_bucket.app_data.bucket
}
