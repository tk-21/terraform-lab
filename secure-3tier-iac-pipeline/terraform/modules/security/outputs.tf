output "ec2_role_arn" {
  description = "EC2 IAM role ARN"
  value       = aws_iam_role.ec2.arn
}

output "ec2_role_name" {
  description = "EC2 IAM role name"
  value       = aws_iam_role.ec2.name
}

output "ec2_instance_profile_name" {
  description = "EC2 IAM instance profile name — Launch Template で参照"
  value       = aws_iam_instance_profile.ec2.name
}

output "ec2_instance_profile_arn" {
  description = "EC2 IAM instance profile ARN"
  value       = aws_iam_instance_profile.ec2.arn
}

output "alb_sg_id" {
  description = "ALB Security Group ID"
  value       = aws_security_group.alb.id
}

output "ec2_sg_id" {
  description = "EC2 Security Group ID — Phase 3 で RDS SG のインバウンドルール用"
  value       = aws_security_group.ec2.id
}

output "rds_sg_id" {
  description = "RDS Security Group ID — Phase 3 で RDS Aurora に割り当て"
  value       = aws_security_group.rds.id
}

output "session_logs_bucket_name" {
  description = "S3 bucket name for SSM Session Manager logs"
  value       = aws_s3_bucket.session_logs.bucket
}

output "session_logs_bucket_arn" {
  description = "S3 bucket ARN for SSM Session Manager logs"
  value       = aws_s3_bucket.session_logs.arn
}
