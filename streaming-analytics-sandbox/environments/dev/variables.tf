variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "Project name used for naming and tagging"
  type        = string
  default     = "streaming-analytics-sandbox"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner name for resource tagging"
  type        = string
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications (empty = no subscription)"
  type        = string
  default     = ""
}

variable "kinesis_shard_count" {
  description = "Number of shards for Kinesis Data Streams (1 shard = 1 MB/s write, 2 MB/s read)"
  type        = number
  default     = 1
}

variable "firehose_buffer_size_mb" {
  description = "Firehose buffer size in MB before flushing to S3 (minimum 64 MB for dynamic partitioning)"
  type        = number
  default     = 64
}

variable "firehose_buffer_interval_seconds" {
  description = "Firehose buffer interval in seconds before flushing to S3 (60-900)"
  type        = number
  default     = 60
}

variable "raw_retention_days" {
  description = "Days to retain raw data in S3 before transitioning to STANDARD_IA"
  type        = number
  default     = 30
}

variable "athena_bytes_scanned_cutoff" {
  description = "Maximum bytes scanned per Athena query for cost guard (default: 1 GB)"
  type        = number
  default     = 1073741824 # 1 GB
}
