# --- producer ---

output "api_endpoint" {
  description = "API Gateway invoke URL (base)"
  value       = module.producer.api_endpoint
}

output "events_endpoint" {
  description = "POST /events endpoint URL"
  value       = module.producer.events_endpoint
}

output "api_key_id" {
  description = "API Key ID (retrieve value: aws apigateway get-api-key --api-key <id> --include-value)"
  value       = module.producer.api_key_id
}

# --- kinesis ---

output "kinesis_stream_name" {
  description = "Kinesis Data Streams stream name"
  value       = module.kinesis.kinesis_stream_name
}

output "firehose_stream_name" {
  description = "Amazon Data Firehose delivery stream name"
  value       = module.kinesis.firehose_stream_name
}

# --- data-lake ---

output "raw_bucket_id" {
  description = "S3 raw zone bucket name"
  value       = module.data_lake.raw_bucket_id
}

output "processed_bucket_id" {
  description = "S3 processed zone bucket name"
  value       = module.data_lake.processed_bucket_id
}

# --- glue ---

output "glue_database_name" {
  description = "Glue Catalog database name"
  value       = module.glue.glue_database_name
}

output "glue_crawler_name" {
  description = "Glue Crawler name"
  value       = module.glue.glue_crawler_name
}

output "glue_job_name" {
  description = "Glue ETL Job name"
  value       = module.glue.glue_job_name
}

# --- athena ---

output "athena_workgroup_name" {
  description = "Athena Workgroup name"
  value       = module.athena.athena_workgroup_name
}

output "athena_results_bucket_id" {
  description = "S3 bucket for Athena query results"
  value       = module.data_lake.athena_results_bucket_id
}

# --- observability ---

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = module.observability.dashboard_name
}
