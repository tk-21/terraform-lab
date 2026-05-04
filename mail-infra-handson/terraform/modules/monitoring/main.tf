locals {
  tags = merge(var.tags, { Module = "monitoring" })
}

# ============================================================
# SNS Topic（アラーム通知用）
# ============================================================

resource "aws_sns_topic" "alarm" {
  # バウンス率・苦情率が閾値を超えた場合にこのトピック経由でメール通知する
  name              = "mail-handson-alarm-topic"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.tags
}

resource "aws_sns_topic_subscription" "alarm_email" {
  # 初回は確認メールが届くためメール内の「Confirm subscription」リンクをクリックすること
  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

# ============================================================
# CloudWatch アラーム（バウンス率）
# ============================================================

resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate" {
  # バウンス率監視: SES停止基準（5%）より手前の3%で早期検知する
  alarm_name          = "mail-handson-bounce-rate-high"
  alarm_description   = "SESバウンス率が3%を超えました。即座にメール送信を停止して原因を調査してください。SESは5%超でアカウントを自動停止します。"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Reputation.BounceRate"
  namespace           = "AWS/SES"
  period              = 3600
  statistic           = "Average"
  threshold           = 0.03
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = local.tags
}

# ============================================================
# CloudWatch アラーム（苦情率）
# ============================================================

resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate" {
  # 苦情率監視: SES停止基準（0.1%）より手前の0.05%で早期検知する
  alarm_name          = "mail-handson-complaint-rate-high"
  alarm_description   = "SES苦情率が0.05%を超えました。メールコンテンツや送信リストを見直してください。SESは0.1%超でアカウントを自動停止します。"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Reputation.ComplaintRate"
  namespace           = "AWS/SES"
  period              = 3600
  statistic           = "Average"
  threshold           = 0.0005
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]

  tags = local.tags
}

# ============================================================
# CloudWatch ダッシュボード
# ============================================================

resource "aws_cloudwatch_dashboard" "mail" {
  dashboard_name = "mail-handson-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "SES送信数（直近24時間）"
          period  = 3600
          stat    = "Sum"
          metrics = [["AWS/SES", "Send"]]
          view    = "timeSeries"
          start   = "-PT24H"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "バウンス数・バウンス率（直近7日間）"
          period = 86400
          stat   = "Average"
          metrics = [
            ["AWS/SES", "Bounce"],
            ["AWS/SES", "Reputation.BounceRate", { label = "バウンス率（右軸）", yAxis = "right" }]
          ]
          view  = "timeSeries"
          start = "-P7D"
          annotations = {
            horizontal = [{ label = "警告閾値(3%)", value = 0.03, color = "#ff7f0e" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "苦情数・苦情率（直近7日間）"
          period = 86400
          stat   = "Average"
          metrics = [
            ["AWS/SES", "Complaint"],
            ["AWS/SES", "Reputation.ComplaintRate", { label = "苦情率（右軸）", yAxis = "right" }]
          ]
          view  = "timeSeries"
          start = "-P7D"
          annotations = {
            horizontal = [{ label = "警告閾値(0.05%)", value = 0.0005, color = "#d62728" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lambda実行回数・エラー数（bounce_handler）"
          period = 3600
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.bounce_handler_function_name],
            ["AWS/Lambda", "Errors", "FunctionName", var.bounce_handler_function_name, { color = "#d62728" }]
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lambda実行回数・エラー数（spam_handler）"
          period = 3600
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.spam_handler_function_name],
            ["AWS/Lambda", "Errors", "FunctionName", var.spam_handler_function_name, { color = "#d62728" }]
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 12
        width  = 24
        height = 4
        properties = {
          title  = "アラームステータス"
          alarms = [aws_cloudwatch_metric_alarm.ses_bounce_rate.arn, aws_cloudwatch_metric_alarm.ses_complaint_rate.arn]
        }
      }
    ]
  })
}
