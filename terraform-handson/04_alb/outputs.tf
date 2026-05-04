output "alb_dns_name" {
  description = "ALB の DNS 名（ブラウザでアクセスして動作確認 → リロードで別インスタンスに振り分けられる）"
  value       = aws_lb.main.dns_name
}

output "web_url" {
  description = "アクセス URL"
  value       = "http://${aws_lb.main.dns_name}"
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

output "target_group_arn" {
  description = "Target Group ARN"
  value       = aws_lb_target_group.web.arn
}

output "asg_name" {
  description = "Auto Scaling Group 名（AWS コンソールで確認）"
  value       = aws_autoscaling_group.web.name
}
