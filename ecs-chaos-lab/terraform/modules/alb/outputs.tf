output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "ALB DNS 名 (動作確認用 URL)"
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "ターゲットグループ ARN (ECS Service 登録先)"
  value       = aws_lb_target_group.main.arn
}

output "target_group_arn_suffix" {
  description = "ターゲットグループ ARN サフィックス (CloudWatch アラームの dimensions に使用)"
  value       = aws_lb_target_group.main.arn_suffix
}

output "alb_arn_suffix" {
  description = "ALB ARN サフィックス (CloudWatch アラームの dimensions に使用)"
  value       = aws_lb.main.arn_suffix
}
