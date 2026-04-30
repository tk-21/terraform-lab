output "artifacts_bucket_name" {
  description = "SageMaker アーティファクト保存用S3バケット名"
  value       = module.foundation.artifacts_bucket_name
}

output "data_bucket_name" {
  description = "学習・推論データ保存用S3バケット名"
  value       = module.foundation.data_bucket_name
}

output "pipeline_role_arn" {
  description = "SageMaker Pipeline実行ロールのARN"
  value       = module.foundation.pipeline_role_arn
}

output "endpoint_role_arn" {
  description = "SageMaker Endpoint実行ロールのARN"
  value       = module.foundation.endpoint_role_arn
}

output "lambda_base_role_arn" {
  description = "Lambda共通ベースロールのARN"
  value       = module.foundation.lambda_base_role_arn
}

output "processing_ecr_uri" {
  description = "Processing用ECRリポジトリURI"
  value       = module.foundation.processing_ecr_uri
}

output "training_ecr_uri" {
  description = "Training用ECRリポジトリURI"
  value       = module.foundation.training_ecr_uri
}

output "pipeline_name" {
  description = "SageMaker Pipeline名"
  value       = module.pipeline.pipeline_name
}

output "pipeline_arn" {
  description = "SageMaker PipelineのARN"
  value       = module.pipeline.pipeline_arn
}

output "model_package_group_name" {
  description = "Model Package Group名"
  value       = module.pipeline.model_package_group_name
}

output "approval_notifier_lambda_arn" {
  description = "approval_notifier Lambda関数のARN"
  value       = module.registry.approval_notifier_lambda_arn
}

output "approval_notifier_lambda_name" {
  description = "approval_notifier Lambda関数名"
  value       = module.registry.approval_notifier_lambda_name
}

output "deploy_pipeline_arn" {
  description = "デプロイ用CodePipelineのARN"
  value       = module.endpoint.codepipeline_arn
}

output "deploy_pipeline_name" {
  description = "デプロイ用CodePipeline名"
  value       = module.endpoint.codepipeline_name
}

output "inference_endpoint_name" {
  description = "SageMaker推論エンドポイント名（endpoint_model_name設定後に利用可能）"
  value       = module.endpoint.endpoint_name
}
