variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "input_queue_name" {
  description = "SQS input queue name"
  type        = string
}

variable "dlq_name" {
  description = "SQS dead letter queue name"
  type        = string
}

variable "dispatcher_function_name" {
  description = "Dispatcher Lambda function name"
  type        = string
}

variable "stream_processor_function_name" {
  description = "Stream processor Lambda function name"
  type        = string
}

variable "dlq_handler_function_name" {
  description = "DLQ handler Lambda function name"
  type        = string
}

variable "state_machine_name" {
  description = "Step Functions state machine name"
  type        = string
}

variable "state_machine_arn" {
  description = "Step Functions state machine ARN"
  type        = string
}

variable "jobs_table_name" {
  description = "DynamoDB jobs table name"
  type        = string
}

variable "alert_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  type        = string
}

variable "dlq_alarm_threshold" {
  description = "Number of messages in DLQ to trigger alarm"
  type        = number
  default     = 1
}

variable "lambda_error_threshold" {
  description = "Lambda error count to trigger alarm"
  type        = number
  default     = 5
}
