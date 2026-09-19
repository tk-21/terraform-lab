output "s3_bucket_name" {
  description = "tfstate保存用S3バケット名 (backend.tf に記載する)"
  value       = aws_s3_bucket.tfstate.id
}
