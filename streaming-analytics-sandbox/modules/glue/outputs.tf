output "glue_database_name" {
  description = "Glue Catalog database name"
  value       = aws_glue_catalog_database.this.name
}

output "glue_crawler_name" {
  description = "Glue Crawler name"
  value       = aws_glue_crawler.raw.name
}

output "glue_job_name" {
  description = "Glue ETL Job name"
  value       = aws_glue_job.etl.name
}

output "glue_role_arn" {
  description = "IAM role ARN used by Glue"
  value       = aws_iam_role.glue.arn
}
