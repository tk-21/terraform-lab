# observability モジュールのアウトプット定義
# environments/dev/main.tf が参照する値を公開する。
# Lambda Insights レイヤー ARN は循環依存を防ぐために output 経由で渡す
#   （モジュール内での Lambda function resource 変更を避けるため）。

output "lambda_insights_layer_arn" {
  description = <<-EOT
    Lambda Insights レイヤー ARN（arm64・latest）。
    environments/dev/main.tf の各 lambda-function モジュール呼び出し時に
    layers 変数に渡すことで Lambda Insights を有効化する。
    例: layers = [module.observability.lambda_insights_layer_arn]
  EOT
  value = data.aws_ssm_parameter.lambda_insights_layer_arm64.value
}

output "xray_group_arn" {
  description = "X-Ray グループの ARN。X-Ray コンソールでグループフィルタ適用時に参照する。"
  value       = aws_xray_group.pipeline.arn
}

output "xray_group_name" {
  description = "X-Ray グループ名。X-Ray GetGroups API やコンソールでのフィルタに使用する。"
  value       = aws_xray_group.pipeline.group_name
}

output "sampling_rule_name" {
  description = "X-Ray カスタムサンプリングルール名。サンプリング設定の変更・削除時に参照する。"
  value       = aws_xray_sampling_rule.pipeline.rule_name
}

output "dashboard_name" {
  description = "CloudWatch ダッシュボード名。コンソール URL の構築や運用ドキュメントに使用する。"
  value       = aws_cloudwatch_dashboard.pipeline.dashboard_name
}

output "dashboard_arn" {
  description = "CloudWatch ダッシュボードの ARN。IAM ポリシーでダッシュボードへのアクセス制御をする場合に使用する。"
  value       = aws_cloudwatch_dashboard.pipeline.dashboard_arn
}

output "alarm_arns" {
  description = <<-EOT
    全 CloudWatch アラーム ARN のマップ。
    Composite Alarm の構成や運用ツールとの統合で参照する。
    キー: アラームの役割識別子、値: ARN
  EOT
  value = {
    ingestor_error_rate   = aws_cloudwatch_metric_alarm.ingestor_error_rate.arn
    transformer_error_rate = aws_cloudwatch_metric_alarm.transformer_error_rate.arn
    ingest_dlq_depth      = aws_cloudwatch_metric_alarm.ingest_dlq_depth.arn
    transform_dlq_depth   = aws_cloudwatch_metric_alarm.transform_dlq_depth.arn
    kinesis_iterator_age  = aws_cloudwatch_metric_alarm.kinesis_iterator_age.arn
    lambda_throttles      = aws_cloudwatch_metric_alarm.lambda_throttles.arn
    cold_start_rate       = aws_cloudwatch_metric_alarm.cold_start_rate.arn
  }
}

output "log_insights_query_ids" {
  description = "保存済み Log Insights クエリの ID マップ。CloudWatch コンソールのクエリ選択 UI で使用する。"
  value = {
    error_logs         = aws_cloudwatch_query_definition.error_logs.id
    processing_latency = aws_cloudwatch_query_definition.processing_latency.id
    dlq_failure_trace  = aws_cloudwatch_query_definition.dlq_failure_trace.id
  }
}
