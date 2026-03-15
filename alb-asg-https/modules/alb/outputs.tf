output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "http_listener_mode" {
  description = "http listener mode: fixed-response (http only) or redirect (to https)"
  value       = var.enable_https_listener ? "redirect" : "fixed-response"
}

output "http_listener_arn" {
  description = "ARN of active HTTP listener"
  value = (
    var.enable_https_listener
    ? try(aws_lb_listener.http_redirect[0].arn, null)
    : try(aws_lb_listener.http_fixed[0].arn, null)
  )
}

output "https_listener_arn" {
  description = "ARN of HTTPS listener (null if not created)"
  value       = try(aws_lb_listener.https[0].arn, null)
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone id (for Route53 alias)"
  value       = aws_lb.this.zone_id
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.this.arn
}

output "target_group_arn" {
  description = "Target group ARN"
  value       = aws_lb_target_group.web.arn
}

output "lb_arn_suffix" {
  description = "ALB ARN suffix (for CloudWatch/ASG metrics label)"
  value       = aws_lb.this.arn_suffix
}

output "tg_arn_suffix" {
  description = "Target group ARN suffix (for CloudWatch/ASG metrics label)"
  value       = aws_lb_target_group.web.arn_suffix
}

output "web_sg_id" {
  description = "Security group id for web instances"
  value       = aws_security_group.web.id
}
