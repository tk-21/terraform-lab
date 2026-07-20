output "inventory_check_arn" { value = aws_lambda_function.inventory_check.arn }
output "notification_arn" { value = aws_lambda_function.notification.arn }
output "dlq_reprocessor_arn" { value = aws_lambda_function.dlq_reprocessor.arn }
output "lambda_sg_id" { value = aws_security_group.lambda.id }
output "inventory_check_function_name" { value = aws_lambda_function.inventory_check.function_name }
output "notification_function_name" { value = aws_lambda_function.notification.function_name }
output "dlq_reprocessor_function_name" { value = aws_lambda_function.dlq_reprocessor.function_name }
