output "pipeline_name" {
  description = "SageMaker Pipeline名"
  value       = aws_sagemaker_pipeline.main.pipeline_name
}

output "pipeline_arn" {
  description = "SageMaker PipelineのARN"
  value       = aws_sagemaker_pipeline.main.arn
}

output "model_package_group_name" {
  description = "Model Package Group名"
  value       = aws_sagemaker_model_package_group.main.model_package_group_name
}

output "model_package_group_arn" {
  description = "Model Package GroupのARN"
  value       = aws_sagemaker_model_package_group.main.arn
}
