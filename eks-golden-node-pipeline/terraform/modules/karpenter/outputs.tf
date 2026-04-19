output "resolved_ami_id" {
  description = "Karpenter EC2NodeClass で使用する AMI ID"
  value       = local.resolved_ami_id
}

output "interruption_queue_name" {
  description = "Spot 中断通知用 SQS キュー名"
  value       = aws_sqs_queue.karpenter_interruption.name
}
