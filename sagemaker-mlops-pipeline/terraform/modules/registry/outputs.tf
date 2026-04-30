output "approval_notifier_lambda_arn" {
  description = "approval_notifier Lambda関数のARN"
  value       = aws_lambda_function.approval_notifier.arn
}

output "approval_notifier_lambda_name" {
  description = "approval_notifier Lambda関数名"
  value       = aws_lambda_function.approval_notifier.function_name
}

output "model_approval_event_rule_arn" {
  description = "Model Registry承認イベントルールのARN"
  value       = aws_cloudwatch_event_rule.model_approval.arn
}

output "model_approved_event_rule_arn" {
  description = "モデル承認→CodePipelineトリガーイベントルールのARN"
  value       = aws_cloudwatch_event_rule.model_approved.arn
}
