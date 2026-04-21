output "database_name" {
  description = "Name of the Glue catalog database"
  value       = aws_glue_catalog_database.main.name
}

output "raw_table_name" {
  description = "Name of the raw logs Glue table"
  value       = aws_glue_catalog_table.raw_logs.name
}

output "processed_table_name" {
  description = "Name of the processed logs Glue table"
  value       = aws_glue_catalog_table.processed_logs.name
}

output "athena_workgroup_name" {
  description = "Name of the Athena workgroup"
  value       = aws_athena_workgroup.main.name
}
