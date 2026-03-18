output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.networking.public_subnet_ids
}

output "bedrock_iam_role_arn" {
  description = "IAM role ARN for Bedrock invocation"
  value       = module.bedrock_foundation.bedrock_iam_role_arn
}

output "guardrail_id" {
  description = "Bedrock Guardrail ID"
  value       = module.bedrock_foundation.guardrail_id
}

output "guardrail_arn" {
  description = "Bedrock Guardrail ARN"
  value       = module.bedrock_foundation.guardrail_arn
}

# --- knowledge-base ---

output "kb_documents_bucket" {
  description = "S3 bucket name for knowledge base documents"
  value       = module.knowledge_base.documents_bucket_name
}

output "kb_aurora_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = module.knowledge_base.aurora_endpoint
}

output "kb_aurora_secret_arn" {
  description = "Secrets Manager ARN for Aurora master credentials"
  value       = module.knowledge_base.aurora_secret_arn
  sensitive   = true
}

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID"
  value       = module.knowledge_base.knowledge_base_id
}

output "knowledge_base_arn" {
  description = "Bedrock Knowledge Base ARN"
  value       = module.knowledge_base.knowledge_base_arn
}

# --- multi-tenant ---

output "tenant_table_name" {
  description = "DynamoDB table name for tenant configuration"
  value       = module.multi_tenant.tenant_table_name
}

output "usage_table_name" {
  description = "DynamoDB table name for token usage tracking"
  value       = module.multi_tenant.usage_table_name
}

# --- router-lambda ---

output "router_lambda_name" {
  description = "Router Lambda function name"
  value       = module.router_lambda.lambda_function_name
}

output "router_lambda_arn" {
  description = "Router Lambda function ARN"
  value       = module.router_lambda.lambda_function_arn
}

output "router_lambda_invoke_arn" {
  description = "Router Lambda invoke ARN (for API Gateway integration)"
  value       = module.router_lambda.lambda_invoke_arn
}

# --- api-gateway ---

output "api_endpoint" {
  description = "HTTP API endpoint URL"
  value       = module.api_gateway.api_endpoint
}

output "chat_endpoint" {
  description = "POST /chat endpoint URL"
  value       = module.api_gateway.chat_endpoint
}

output "waf_web_acl_arn" {
  description = "WAF WebACL ARN"
  value       = module.api_gateway.waf_web_acl_arn
}

# --- cost-controller ---

output "budget_alert_topic_arn" {
  description = "SNS topic ARN for budget and alarm notifications"
  value       = module.cost_controller.alert_topic_arn
}

output "monthly_budget_name" {
  description = "AWS Budgets budget name"
  value       = module.cost_controller.budget_name
}

output "cost_controller_lambda_name" {
  description = "Cost controller Lambda function name"
  value       = module.cost_controller.lambda_function_name
}

# --- bedrock-agent ---

output "bedrock_agent_id" {
  description = "Bedrock Agent ID"
  value       = module.bedrock_agent.agent_id
}

output "bedrock_agent_arn" {
  description = "Bedrock Agent ARN"
  value       = module.bedrock_agent.agent_arn
}

# --- observability ---

output "cloudwatch_dashboard_name" {
  description = "CloudWatch Dashboard name"
  value       = module.observability.dashboard_name
}

output "xray_group_name" {
  description = "X-Ray group name for Lambda tracing"
  value       = module.observability.xray_group_name
}
