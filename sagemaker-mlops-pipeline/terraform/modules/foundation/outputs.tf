output "artifacts_bucket_name" {
  description = "SageMaker アーティファクト保存用S3バケット名"
  value       = aws_s3_bucket.artifacts.bucket
}

output "data_bucket_name" {
  description = "学習・推論データ保存用S3バケット名"
  value       = aws_s3_bucket.data.bucket
}

output "pipeline_role_arn" {
  description = "SageMaker Pipeline実行ロールのARN"
  value       = aws_iam_role.pipeline.arn
}

output "endpoint_role_arn" {
  description = "SageMaker Endpoint実行ロールのARN"
  value       = aws_iam_role.endpoint.arn
}

output "lambda_base_role_arn" {
  description = "Lambda共通ベースロールのARN"
  value       = aws_iam_role.lambda_base.arn
}

output "processing_ecr_uri" {
  description = "Processing用ECRリポジトリURI"
  value       = aws_ecr_repository.processing.repository_url
}

output "training_ecr_uri" {
  description = "Training用ECRリポジトリURI"
  value       = aws_ecr_repository.training.repository_url
}
