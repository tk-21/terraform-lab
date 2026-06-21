output "project_name" {
  description = "CodeBuild プロジェクト名"
  value       = aws_codebuild_project.app.name
}

output "role_arn" {
  description = "CodeBuild 実行ロール ARN"
  value       = aws_iam_role.codebuild.arn
}
