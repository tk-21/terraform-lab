output "tfstate_bucket_name" {
  description = "environments/dev/main.tfのbackend設定にコピーして使う"
  value       = aws_s3_bucket.tfstate.bucket
}

output "tflock_table_name" {
  description = "environments/dev/main.tfのbackend設定にコピーして使う"
  value       = aws_dynamodb_table.tflock.name
}
