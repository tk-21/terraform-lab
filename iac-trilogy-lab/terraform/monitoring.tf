# -----------------------------------------------------------------------
# SNS トピック: アラート通知共通
# -----------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${local.prefix}-alerts"

  # 転送中のメッセージをKMSで暗号化
  # SNSトピックに機密情報（コスト情報・EC2メトリクス）が流れるため
  # kms_master_key_id を指定しない場合はSSE-SNS（管理キー）が使われる
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name = "${local.prefix}-alerts"
  }
}

# SNS メール購読
# 注意: apply 後、指定アドレスに確認メールが届く。
# リンクをクリックして購読を確認しないとアラートが届かない。
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# -----------------------------------------------------------------------
# AWS Budgets: 月次コストアラート
# -----------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${local.prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = "10"
  limit_unit   = "USD"
  # MONTHLY: 月初にリセット。検証ラボの $1〜3/月 に対して $10 の余裕を持たせる
  time_unit = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    # 100% 超え（= 予算超過）の際にも別途通知
    # 80% 通知だけでは実際の超過に気づくのが遅れる可能性があるため
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }
}

# -----------------------------------------------------------------------
# CloudWatch Alarm: EC2 CPU使用率監視
# -----------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ec2_cpu" {
  alarm_name          = "${local.prefix}-cpu-alarm"
  alarm_description   = "EC2 CPU使用率が80%を2回連続で超えた場合にアラート"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  # period = 300 (5分): 短すぎるとノイズが多く、長すぎると反応が遅れる。5分が標準的な妥協点
  period    = 300
  statistic = "Average"
  threshold = 80

  dimensions = {
    InstanceId = aws_instance.app.id
  }

  # アラーム発火時: SNSトピックへ通知
  alarm_actions = [aws_sns_topic.alerts.arn]
  # アラーム解除時も通知: 復旧確認のため
  ok_actions = [aws_sns_topic.alerts.arn]

  # データポイント不足時の動作: MISSING → アラームにしない
  # インスタンス停止中に誤アラートが発火するのを防ぐ
  treat_missing_data = "notBreaching"

  tags = {
    Name = "${local.prefix}-cpu-alarm"
  }
}
