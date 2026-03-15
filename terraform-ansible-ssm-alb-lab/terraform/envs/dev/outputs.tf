output "instance_id" {
  value = aws_instance.web.id
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_url" {
  value = "http://${aws_lb.this.dns_name}/"
}

output "ssm_transfer_bucket" {
  value = aws_s3_bucket.ssm_transfer.bucket
}
