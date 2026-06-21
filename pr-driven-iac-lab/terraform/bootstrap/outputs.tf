output "s3_bucket_name" {
  description = "TerraformステートファイルのS3バケット名"
  value       = aws_s3_bucket.tfstate.bucket
}

output "dynamodb_table_name" {
  description = "Terraformステートロック用DynamoDBテーブル名"
  value       = aws_dynamodb_table.tfstate_lock.name
}
