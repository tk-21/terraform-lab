output "pipeline_name" {
  description = "CodePipeline パイプライン名"
  value       = aws_codepipeline.main.name
}
