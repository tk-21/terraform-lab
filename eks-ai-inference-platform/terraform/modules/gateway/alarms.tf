# ────────────────────────────────────────────────
# SNS トピック: コストアラート通知ルーティング
# ────────────────────────────────────────────────

resource "aws_sns_topic" "cost_alert" {
  name = "${local.name_prefix}-cost-alert"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.cost_alert.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_alert.arn
}

# ────────────────────────────────────────────────
# CloudWatch Alarm: 時間コスト超過検知
# ────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "inference_cost" {
  alarm_name          = "${local.name_prefix}-inference-hourly-cost-exceeded"
  alarm_description   = "AI推論の時間コストが ${var.hourly_budget_usd} USD を超過: Bedrockフォールバック中"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  # OTEL Collector が CloudWatch EMF エクスポーターで書き込むカスタムメトリクス
  # 前提: k8s/otel/collector.yaml に awsemf エクスポーターを追加すること
  metric_name = "inference_cost_usd"
  namespace   = "AI/Inference"
  period      = 3600
  statistic   = "Sum"
  threshold   = var.hourly_budget_usd

  # データポイント欠如は「正常」と見なす: ゼロトラフィック時に誤検知しないようにする
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.cost_alert.arn]
  ok_actions    = [aws_sns_topic.cost_alert.arn]

  tags = local.common_tags
}

# ────────────────────────────────────────────────
# CloudWatch Log Group: Lambda ログ
# ────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "cost_alert_lambda" {
  # Lambda 関数名に対応したロググループを事前作成して保持期間を管理する
  name              = "/aws/lambda/${aws_lambda_function.cost_alert.function_name}"
  retention_in_days = 30

  tags = local.common_tags
}
