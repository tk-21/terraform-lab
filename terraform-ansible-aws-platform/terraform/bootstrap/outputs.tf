output "state_bucket_name" {
  description = "Terraformステート保存用S3バケット名"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "lock_table_name" {
  description = "Terraformステートロック用DynamoDBテーブル名"
  value       = aws_dynamodb_table.terraform_lock.name
}
