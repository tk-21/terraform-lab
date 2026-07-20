output "state_machine_arn" { value = aws_sfn_state_machine.order_pipeline.arn }
output "state_machine_name" { value = aws_sfn_state_machine.order_pipeline.name }
output "sfn_trigger_function_name" { value = aws_lambda_function.sfn_trigger.function_name }
