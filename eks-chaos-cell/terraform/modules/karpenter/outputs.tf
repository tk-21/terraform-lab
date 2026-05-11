output "karpenter_role_arn" {
  description = "KarpenterコントローラーIAMロールARN"
  value       = aws_iam_role.karpenter_controller.arn
}

output "interruption_queue_name" {
  description = "Spot中断通知SQSキュー名"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "interruption_queue_arn" {
  description = "Spot中断通知SQSキューARN"
  value       = aws_sqs_queue.karpenter_interruption.arn
}
