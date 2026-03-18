output "dashboard_name" {
  description = "CloudWatch Dashboard name"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_arn" {
  description = "CloudWatch Dashboard ARN"
  value       = aws_cloudwatch_dashboard.main.dashboard_arn
}

output "xray_group_name" {
  description = "X-Ray group name"
  value       = aws_xray_group.lambdas.group_name
}

output "xray_group_arn" {
  description = "X-Ray group ARN"
  value       = aws_xray_group.lambdas.arn
}

output "router_lambda_alarm_arn" {
  description = "CloudWatch Alarm ARN for router Lambda errors"
  value       = aws_cloudwatch_metric_alarm.router_lambda_errors.arn
}

output "api_5xx_alarm_arn" {
  description = "CloudWatch Alarm ARN for API Gateway 5xx errors"
  value       = aws_cloudwatch_metric_alarm.api_5xx.arn
}

output "bedrock_metric_namespace" {
  description = "CloudWatch custom metric namespace for Bedrock invocations"
  value       = "${var.project}/${var.environment}"
}
