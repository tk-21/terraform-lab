output "alarm_name" {
  description = "WAF ブロック数 CloudWatch アラーム名"
  value       = aws_cloudwatch_metric_alarm.waf_block_high.alarm_name
}

output "lambda_function_name" {
  description = "alert_notifier Lambda 関数名"
  value       = aws_lambda_function.alert_notifier.function_name
}

output "lambda_function_arn" {
  description = "alert_notifier Lambda 関数 ARN"
  value       = aws_lambda_function.alert_notifier.arn
}

output "eventbridge_rule_name" {
  description = "EventBridge ルール名"
  value       = aws_cloudwatch_event_rule.waf_alarm.name
}
