output "s3_lambda_arn" {
  description = "S3修復Lambda ARN (config/security_hubモジュールのEventBridgeターゲットで使用)"
  value       = aws_lambda_function.s3_remediation.arn
}

output "iam_lambda_arn" {
  description = "IAM修復Lambda ARN"
  value       = aws_lambda_function.iam_remediation.arn
}

output "sg_lambda_arn" {
  description = "EC2/SG修復Lambda ARN"
  value       = aws_lambda_function.sg_remediation.arn
}

output "rds_lambda_arn" {
  description = "RDS修復Lambda ARN"
  value       = aws_lambda_function.rds_remediation.arn
}

output "shared_layer_arn" {
  description = "共有モジュールLayerのARN (audit_logger + chatwork_notifier)"
  value       = aws_lambda_layer_version.csar_shared.arn
}
