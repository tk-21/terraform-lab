variable "bedrock_model_id" {
  description = "Bedrock foundation model ID"
  type        = string
}

variable "aws_inspector_lambda_arn" {
  description = "ARN of aws_inspector Lambda function"
  type        = string
}

variable "report_writer_lambda_arn" {
  description = "ARN of report_writer Lambda function"
  type        = string
}

variable "notifier_lambda_arn" {
  description = "ARN of notifier Lambda function"
  type        = string
}
