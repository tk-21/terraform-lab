output "codepipeline_arn" {
  description = "デプロイ用CodePipelineのARN"
  value       = aws_codepipeline.deploy.arn
}

output "codepipeline_name" {
  description = "デプロイ用CodePipeline名"
  value       = aws_codepipeline.deploy.name
}

output "eventbridge_codepipeline_role_arn" {
  description = "EventBridgeがCodePipelineを起動するIAMロールのARN"
  value       = aws_iam_role.eventbridge_codepipeline.arn
}

output "codebuild_project_name" {
  description = "デプロイ用CodeBuildプロジェクト名"
  value       = aws_codebuild_project.deploy.name
}

output "endpoint_name" {
  description = "SageMaker Endpoint名（endpoint_model_nameが設定されている場合のみ）"
  value       = var.endpoint_model_name != "" ? aws_sagemaker_endpoint.main[0].name : null
}
