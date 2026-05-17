output "instance_id" {
  description = "EC2 インスタンス ID"
  value       = aws_instance.test.id
}

output "instance_private_ip" {
  description = "EC2 インスタンスのプライベート IP"
  value       = aws_instance.test.private_ip
}

output "iam_role_arn" {
  description = "EC2 SSM 用 IAM ロール ARN"
  value       = aws_iam_role.ec2_ssm.arn
}
