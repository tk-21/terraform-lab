output "table_name" {
  value = aws_dynamodb_table.sensor_data.name
}

output "table_arn" {
  value = aws_dynamodb_table.sensor_data.arn
}
