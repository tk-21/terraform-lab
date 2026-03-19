# --- api-ingestor ---

output "api_endpoint" {
  description = "API Gateway invoke URL"
  value       = module.api_ingestor.api_endpoint
}

output "jobs_endpoint" {
  description = "POST /jobs endpoint URL"
  value       = module.api_ingestor.jobs_endpoint
}

output "api_key_id" {
  description = "API Gateway API Key ID (retrieve value: aws apigateway get-api-key --api-key <id> --include-value)"
  value       = module.api_ingestor.api_key_id
}

# --- messaging ---

output "input_queue_url" {
  description = "SQS input queue URL"
  value       = module.messaging.input_queue_url
}

output "notification_topic_arn" {
  description = "SNS notification topic ARN"
  value       = module.messaging.notification_topic_arn
}

# --- storage ---

output "jobs_table_name" {
  description = "DynamoDB jobs table name"
  value       = module.storage.jobs_table_name
}

output "metrics_table_name" {
  description = "DynamoDB metrics table name"
  value       = module.storage.metrics_table_name
}

# --- workflow ---

output "state_machine_arn" {
  description = "Step Functions state machine ARN"
  value       = module.workflow.state_machine_arn
}

output "state_machine_name" {
  description = "Step Functions state machine name"
  value       = module.workflow.state_machine_name
}

# --- observability ---

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = module.observability.dashboard_name
}

# --- networking ---

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}
