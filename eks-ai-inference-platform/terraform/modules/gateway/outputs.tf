output "ecr_repository_url" {
  description = "AI Gateway ECR リポジトリ URL (docker push / k8s deployment.yaml のイメージ参照に使用)"
  value       = aws_ecr_repository.ai_gateway.repository_url
}

output "gateway_irsa_role_arn" {
  description = "AI Gateway IRSA ロール ARN (k8s/gateway/serviceaccount.yaml のアノテーションに設定)"
  value       = aws_iam_role.gateway_sa.arn
}

output "cost_alert_lambda_arn" {
  description = "コストアラート Lambda ARN"
  value       = aws_lambda_function.cost_alert.arn
}

output "cost_alert_sns_topic_arn" {
  description = "コストアラート SNS トピック ARN"
  value       = aws_sns_topic.cost_alert.arn
}

output "cloudwatch_alarm_name" {
  description = "推論コスト超過 CloudWatch アラーム名 (AMG ダッシュボードのアラートパネルに使用)"
  value       = aws_cloudwatch_metric_alarm.inference_cost.alarm_name
}

output "lambda_dlq_url" {
  description = "コストアラート Lambda DLQ URL (障害調査時に未処理メッセージを確認する)"
  value       = aws_sqs_queue.lambda_dlq.url
}
