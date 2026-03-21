variable "project" {
  description = "Project name used for naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "aws_region" {
  description = "AWS region (used to build Kinesis integration URI)"
  type        = string
}

variable "kinesis_stream_name" {
  description = "Kinesis Data Streams stream name"
  type        = string
}

variable "kinesis_stream_arn" {
  description = "Kinesis Data Streams stream ARN"
  type        = string
}
