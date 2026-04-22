output "glue_database_name" {
  description = "Glue Catalog database name"
  value       = aws_glue_catalog_database.streaming.name
}

output "glue_table_name" {
  description = "Glue Catalog table name"
  value       = aws_glue_catalog_table.service_metrics.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup name"
  value       = aws_athena_workgroup.streaming.name
}
