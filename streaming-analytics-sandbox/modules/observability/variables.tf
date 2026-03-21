variable "project" {
  description = "Project name used for naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "kinesis_stream_name" {
  description = "Kinesis Data Streams stream name"
  type        = string
}

variable "firehose_stream_name" {
  description = "Amazon Data Firehose delivery stream name"
  type        = string
}

variable "transform_lambda_name" {
  description = "Firehose transformation Lambda function name"
  type        = string
}

variable "glue_job_name" {
  description = "Glue ETL Job name"
  type        = string
}

variable "athena_workgroup_name" {
  description = "Athena Workgroup name"
  type        = string
}

variable "raw_bucket_id" {
  description = "S3 raw zone bucket name"
  type        = string
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications (empty = no subscription)"
  type        = string
  default     = ""
}
