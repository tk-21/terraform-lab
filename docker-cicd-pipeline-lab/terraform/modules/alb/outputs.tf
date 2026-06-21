output "alb_dns_name" { value = aws_lb.main.dns_name }
output "alb_arn" { value = aws_lb.main.arn }
output "tg_blue_arn" { value = aws_lb_target_group.blue.arn }
output "tg_green_arn" { value = aws_lb_target_group.green.arn }
output "listener_http_arn" { value = aws_lb_listener.http.arn }
output "listener_test_arn" { value = aws_lb_listener.test.arn }
output "tg_blue_name" { value = aws_lb_target_group.blue.name }
output "tg_green_name" { value = aws_lb_target_group.green.name }
output "alb_arn_suffix" {
  # CloudWatch メトリクスのディメンジョンには ARN 全体ではなくサフィックス形式が必要
  value = aws_lb.main.arn_suffix
}
