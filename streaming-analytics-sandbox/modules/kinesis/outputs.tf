output "kinesis_stream_name" {
  description = "Kinesis Data Streams stream name"
  value       = aws_kinesis_stream.events.name
}

output "kinesis_stream_arn" {
  description = "Kinesis Data Streams stream ARN"
  value       = aws_kinesis_stream.events.arn
}

output "firehose_stream_name" {
  description = "Amazon Data Firehose delivery stream name"
  value       = aws_kinesis_firehose_delivery_stream.events.name
}

output "firehose_stream_arn" {
  description = "Amazon Data Firehose delivery stream ARN"
  value       = aws_kinesis_firehose_delivery_stream.events.arn
}

output "transform_lambda_name" {
  description = "Firehose transformation Lambda function name"
  value       = aws_lambda_function.transform.function_name
}

output "transform_lambda_arn" {
  description = "Firehose transformation Lambda function ARN"
  value       = aws_lambda_function.transform.arn
}
