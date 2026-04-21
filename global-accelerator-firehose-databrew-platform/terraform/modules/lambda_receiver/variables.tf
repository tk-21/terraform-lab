variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "receiver_role_arn" {
  description = "ARN of the IAM role for Lambda Receiver"
  type        = string
}

variable "firehose_stream_name" {
  description = "Name of the Kinesis Data Firehose delivery stream"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for VPC config"
  type        = list(string)
}

variable "sg_lambda_receiver_id" {
  description = "Security group ID for Lambda Receiver"
  type        = string
}

variable "alb_target_group_arn" {
  description = "ARN of the ALB target group (used for Lambda permission)"
  type        = string
  default     = ""
}
