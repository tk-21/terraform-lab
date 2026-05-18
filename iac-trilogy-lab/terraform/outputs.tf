output "vpc_id" {
  description = "VPCのID"
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "パブリックサブネットのID"
  value       = aws_subnet.public.id
}

output "ec2_instance_id" {
  description = "EC2インスタンスID（SSM接続時に使用: aws ssm start-session --target <id>）"
  value       = aws_instance.app.id
}

output "ec2_public_ip" {
  description = "EC2パブリックIP（参考用。接続はSSMを使うこと）"
  value       = aws_instance.app.public_ip
}

output "ec2_ami_id" {
  description = "使用されたAMIのID（Amazon Linux 2023 arm64）"
  value       = data.aws_ami.al2023_arm64.id
}

output "s3_bucket_name" {
  description = "アーティファクト用S3バケット名"
  value       = aws_s3_bucket.artifacts.id
}

output "s3_bucket_arn" {
  description = "アーティファクト用S3バケットARN"
  value       = aws_s3_bucket.artifacts.arn
}

output "sns_topic_arn" {
  description = "アラート通知用SNSトピックARN"
  value       = aws_sns_topic.alerts.arn
}

output "ssm_connect_command" {
  description = "SSM Session Manager 接続コマンド（コピペで使用可能）"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ap-northeast-1"
}

output "s3_upload_test_command" {
  description = "S3アップロード検証コマンド（EC2上で実行）"
  value       = "echo 'itl-phase1-test' | aws s3 cp - s3://${aws_s3_bucket.artifacts.id}/test.txt"
}
