# デプロイ後に参照したい主要な識別子をまとめて出力する。
output "region" { value = var.region }
output "cluster_name" { value = module.eks.cluster_name }

output "ecr_repo_url" { value = aws_ecr_repository.app.repository_url }
output "app_image" { value = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}" }

output "irsa_app_role_arn" { value = module.irsa_app.iam_role_arn }

output "knowledge_bucket" { value = aws_s3_bucket.knowledge.bucket }

output "knowledge_base_id" { value = try(aws_bedrockagent_knowledge_base.this.id, "") }
output "data_source_id" { value = try(aws_bedrockagent_data_source.s3.id, "") }

output "alb_logs_bucket" { value = try(aws_s3_bucket.alb_logs.bucket, "") }
