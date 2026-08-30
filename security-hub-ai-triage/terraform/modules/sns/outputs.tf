output "topic_arn" {
  description = "高優先度 Finding の通知先 SNS Topic ARN"
  value       = aws_sns_topic.alerts.arn
}
