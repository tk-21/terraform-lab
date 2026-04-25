output "alb_dns_name" {
  description = "ALBのDNS名（ブラウザアクセス用）"
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "Target Group ARN"
  value       = aws_lb_target_group.app.arn
}

output "alb_arn_suffix" {
  description = "ALBのARNサフィックス（CloudWatchメトリクス用）"
  value       = aws_lb.main.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target GroupのARNサフィックス（CloudWatchメトリクス用）"
  value       = aws_lb_target_group.app.arn_suffix
}
