output "input_queue_url" {
  description = "SQS input queue URL"
  value       = aws_sqs_queue.input.url
}

output "input_queue_arn" {
  description = "SQS input queue ARN"
  value       = aws_sqs_queue.input.arn
}

output "input_queue_name" {
  description = "SQS input queue name"
  value       = aws_sqs_queue.input.name
}

output "dlq_arn" {
  description = "Dead letter queue ARN"
  value       = aws_sqs_queue.input_dlq.arn
}

output "dlq_name" {
  description = "Dead letter queue name"
  value       = aws_sqs_queue.input_dlq.name
}

output "notification_topic_arn" {
  description = "SNS topic ARN for job notifications"
  value       = aws_sns_topic.notifications.arn
}

output "alert_topic_arn" {
  description = "SNS topic ARN for operational alerts"
  value       = aws_sns_topic.alerts.arn
}
