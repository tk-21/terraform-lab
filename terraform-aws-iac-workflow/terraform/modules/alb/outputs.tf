output "dns_name" {
  value = aws_lb.this.dns_name
}

output "http_listener_arn" {
  value = aws_lb_listener.http.arn
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}
