output "alb_arn" {
  description = "ALB の ARN（WAF WebACL のアタッチに使用）"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "ALB の DNS 名（動作確認用 curl のエンドポイント）"
  value       = aws_lb.main.dns_name
}
