output "documents_bucket_name" {
  description = "S3 bucket name for knowledge base documents"
  value       = aws_s3_bucket.documents.id
}

output "documents_bucket_arn" {
  description = "S3 bucket ARN for knowledge base documents"
  value       = aws_s3_bucket.documents.arn
}

output "aurora_cluster_arn" {
  description = "Aurora cluster ARN"
  value       = aws_rds_cluster.main.arn
}

output "aurora_cluster_identifier" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.main.cluster_identifier
}

output "aurora_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.main.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "aurora_secret_arn" {
  description = "Secrets Manager ARN for Aurora master credentials"
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}

output "aurora_security_group_id" {
  description = "Security group ID for Aurora cluster"
  value       = aws_security_group.aurora.id
}

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID"
  value       = aws_bedrockagent_knowledge_base.main.id
}

output "knowledge_base_arn" {
  description = "Bedrock Knowledge Base ARN"
  value       = aws_bedrockagent_knowledge_base.main.arn
}

output "data_source_id" {
  description = "Bedrock Knowledge Base S3 data source ID"
  value       = aws_bedrockagent_data_source.s3.data_source_id
}

output "bedrock_kb_role_arn" {
  description = "IAM role ARN for Bedrock Knowledge Base"
  value       = aws_iam_role.bedrock_kb.arn
}
