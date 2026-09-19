output "operator_role_arn" {
  description = "OperatorのIRSAロールARN (OperatorのServiceAccountアノテーションに設定する)"
  value       = aws_iam_role.operator.arn
}
