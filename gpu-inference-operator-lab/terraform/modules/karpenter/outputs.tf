output "karpenter_role_arn" {
  description = "KarpenterのIAMロールARN (デバッグ用)"
  value       = aws_iam_role.karpenter.arn
}

output "interruption_queue_url" {
  description = "Spot中断通知用SQSキューURL"
  value       = aws_sqs_queue.karpenter_interruption.url
}

output "gpu_nodepool_name" {
  description = "GPU推論用NodePool名 (AIInferenceServiceのgpuNodePoolRefに設定する値)"
  value       = var.gpu_nodepool_name
}
