output "delivery_stream_name" {
  description = "Name of the Kinesis Data Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.this.name
}

output "delivery_stream_arn" {
  description = "ARN of the Kinesis Data Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.this.arn
}
