output "region" {
  value = var.region
}

output "ssm_transfer_bucket" {
  value = aws_s3_bucket.ssm_transfer.bucket
}

# ALBのアクセス先（これが “入口”）
output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

# ASGの識別（デバッグ用）
output "asg_name" {
  value = aws_autoscaling_group.app.name
}

# RDS接続情報（パスワードは出さない）
output "db_endpoint" {
  value = aws_db_instance.mysql.address
}

output "db_name" {
  value = var.db_name
}

output "db_username" {
  value     = var.db_username
  sensitive = true
}
