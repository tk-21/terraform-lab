output "orders_queue_url" { value = aws_sqs_queue.orders.url }
output "orders_queue_arn" { value = aws_sqs_queue.orders.arn }
output "orders_queue_name" { value = aws_sqs_queue.orders.name }
output "orders_dlq_arn" { value = aws_sqs_queue.orders_dlq.arn }
output "orders_dlq_url" { value = aws_sqs_queue.orders_dlq.url }
output "dlq_alarm_arn" { value = aws_cloudwatch_metric_alarm.dlq_messages.arn }
