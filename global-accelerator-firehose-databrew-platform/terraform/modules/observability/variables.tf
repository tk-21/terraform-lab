variable "name_prefix" {
  description = "Common name prefix for resources"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch metrics"
  type        = string
}

variable "lambda_receiver_function_name" {
  description = "Lambda Receiver function name"
  type        = string
}

variable "lambda_generator_function_name" {
  description = "Lambda Generator function name"
  type        = string
}

variable "firehose_stream_name" {
  description = "Kinesis Data Firehose delivery stream name"
  type        = string
}

variable "databrew_log_group_name" {
  description = "CloudWatch Log Group name for DataBrew job logs"
  type        = string
  default     = "/aws-glue/databrew/jobs"
}
