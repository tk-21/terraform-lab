output "alb_arn" {
  description = "ALB の ARN（FIS 停止条件の監視対象として使用）"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "ALB の DNS 名（動作確認用エンドポイント）"
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "ターゲットグループの ARN（ASG モジュールに渡す）"
  value       = aws_lb_target_group.main.arn
}

output "alb_sg_id" {
  description = "ALB セキュリティグループの ID"
  value       = var.alb_sg_id
}
