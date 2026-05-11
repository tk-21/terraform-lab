output "repository_url" {
  description = "ECR リポジトリ URL (bootstrap.sh でのイメージプッシュ先)"
  value       = aws_ecr_repository.nginx.repository_url
}

output "repository_arn" {
  description = "ECR リポジトリ ARN"
  value       = aws_ecr_repository.nginx.arn
}
