module "data_lake" {
  source = "../../modules/data-lake"

  project            = var.project
  environment        = var.environment
  raw_retention_days = var.raw_retention_days
}

module "kinesis" {
  source = "../../modules/kinesis"

  project     = var.project
  environment = var.environment

  kinesis_shard_count              = var.kinesis_shard_count
  firehose_buffer_size_mb          = var.firehose_buffer_size_mb
  firehose_buffer_interval_seconds = var.firehose_buffer_interval_seconds

  raw_bucket_arn = module.data_lake.raw_bucket_arn
  raw_bucket_id  = module.data_lake.raw_bucket_id
}

module "producer" {
  source = "../../modules/producer"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  kinesis_stream_name = module.kinesis.kinesis_stream_name
  kinesis_stream_arn  = module.kinesis.kinesis_stream_arn
}

module "glue" {
  source = "../../modules/glue"

  project     = var.project
  environment = var.environment

  raw_bucket_id       = module.data_lake.raw_bucket_id
  raw_bucket_arn      = module.data_lake.raw_bucket_arn
  processed_bucket_id  = module.data_lake.processed_bucket_id
  processed_bucket_arn = module.data_lake.processed_bucket_arn
  scripts_bucket_id   = module.data_lake.scripts_bucket_id
  scripts_bucket_arn  = module.data_lake.scripts_bucket_arn
}

module "athena" {
  source = "../../modules/athena"

  project     = var.project
  environment = var.environment

  athena_results_bucket_arn = module.data_lake.athena_results_bucket_arn
  athena_results_bucket_id  = module.data_lake.athena_results_bucket_id
  processed_bucket_id       = module.data_lake.processed_bucket_id
  glue_database_name        = module.glue.glue_database_name
  athena_bytes_scanned_cutoff = var.athena_bytes_scanned_cutoff
}

module "observability" {
  source = "../../modules/observability"

  project     = var.project
  environment = var.environment

  kinesis_stream_name         = module.kinesis.kinesis_stream_name
  firehose_stream_name        = module.kinesis.firehose_stream_name
  transform_lambda_name       = module.kinesis.transform_lambda_name
  glue_job_name               = module.glue.glue_job_name
  athena_workgroup_name       = module.athena.athena_workgroup_name
  raw_bucket_id               = module.data_lake.raw_bucket_id
  alert_email                 = var.alert_email
}
