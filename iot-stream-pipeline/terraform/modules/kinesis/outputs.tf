output "stream_name" {
  value = aws_kinesis_stream.sensor.name
}

output "stream_arn" {
  value = aws_kinesis_stream.sensor.arn
}
