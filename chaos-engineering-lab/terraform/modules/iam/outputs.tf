output "fis_role_arn" {
  description = "FIS 実行ロールの ARN（fis モジュールに渡す）"
  value       = aws_iam_role.fis_execution.arn
}

output "instance_profile_name" {
  description = "EC2 インスタンスプロファイル名（asg モジュールに渡す）"
  value       = aws_iam_instance_profile.ec2.name
}

output "ec2_role_arn" {
  description = "EC2 SSM ロールの ARN"
  value       = aws_iam_role.ec2_ssm.arn
}
