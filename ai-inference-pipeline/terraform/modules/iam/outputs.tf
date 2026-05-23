output "ecs_task_execution_role_arn" { value = aws_iam_role.ecs_task_execution.arn }
output "ecs_task_role_arn" { value = aws_iam_role.ecs_task.arn }
output "lambda_bedrock_role_arn" { value = aws_iam_role.lambda_bedrock.arn }
output "lambda_notify_role_arn" { value = aws_iam_role.lambda_notify.arn }
output "sfn_role_arn" { value = aws_iam_role.sfn.arn }
output "eventbridge_role_arn" { value = aws_iam_role.eventbridge.arn }
