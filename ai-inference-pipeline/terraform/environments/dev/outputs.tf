output "input_bucket_name" {
  value = module.s3.input_bucket_name
}

output "output_bucket_name" {
  value = module.s3.output_bucket_name
}

output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "state_machine_arn" {
  value = module.step_functions.state_machine_arn
}

output "state_machine_name" {
  value = module.step_functions.state_machine_name
}

output "eventbridge_rule" {
  value = module.eventbridge.rule_name
}
