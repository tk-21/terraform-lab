# terraform/environments/prod/outputs.tf

output "api_endpoint" {
  value = module.api_gateway.invoke_url
}

output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

output "audit_bucket_name" {
  value = module.storage.audit_bucket_name
}
