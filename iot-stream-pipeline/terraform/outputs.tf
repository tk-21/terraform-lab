output "kinesis_stream_name" {
  description = "Kinesisストリーム名 (Phase2のLambda設定で使用)"
  value       = module.kinesis.stream_name
}

output "kinesis_stream_arn" {
  description = "KinesisストリームARN"
  value       = module.kinesis.stream_arn
}

output "dynamodb_table_name" {
  description = "DynamoDBテーブル名"
  value       = module.dynamodb.table_name
}

output "dynamodb_table_arn" {
  description = "DynamoDBテーブルARN (IAMポリシーで使用)"
  value       = module.dynamodb.table_arn
}

output "ecr_processor_url" {
  description = "processorコンテナのECRリポジトリURL"
  value       = module.ecr.processor_repository_url
}

output "ecr_reader_url" {
  description = "readerコンテナのECRリポジトリURL"
  value       = module.ecr.reader_repository_url
}

output "aws_account_id" {
  description = "AWSアカウントID (ECR認証で使用)"
  value       = data.aws_caller_identity.current.account_id
}

output "reader_invoke_arn" {
  description = "readerLambdaのinvoke ARN (API Gateway設定で使用)"
  value       = module.lambda.reader_invoke_arn
}

output "api_endpoint" {
  description = "センサーデータ取得APIエンドポイント"
  value       = module.apigateway.api_endpoint
}

output "api_id" {
  description = "API Gateway REST API ID"
  value       = module.apigateway.api_id
}
