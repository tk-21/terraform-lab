variable "project" {
  description = "Project name used for naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "kinesis_shard_count" {
  description = "Number of shards (1 shard = 1 MB/s write, 2 MB/s read)"
  type        = number
  default     = 1
}

variable "firehose_buffer_size_mb" {
  description = "Firehose buffer size in MB (minimum 64 for dynamic partitioning)"
  type        = number
  default     = 64
}

variable "firehose_buffer_interval_seconds" {
  description = "Firehose buffer interval in seconds (60-900)"
  type        = number
  default     = 60
}

variable "raw_bucket_arn" {
  description = "ARN of the S3 raw zone bucket"
  type        = string
}

variable "raw_bucket_id" {
  description = "Name of the S3 raw zone bucket"
  type        = string
}
