output "keda_amp_irsa_arn" {
  description = "KEDA AMPクエリIRSAロールARN (k8s/keda/trigger-authentication.yaml のアノテーションに設定)"
  value       = aws_iam_role.keda_amp_irsa.arn
}

output "scale_notify_lambda_arn" {
  description = "スケール通知Lambda ARN"
  value       = aws_lambda_function.scale_notify.arn
}

output "scale_notify_dlq_url" {
  description = "スケール通知Lambda DLQ URL (障害調査時に未処理メッセージを確認する)"
  value       = aws_sqs_queue.scale_notify_dlq.url
}
