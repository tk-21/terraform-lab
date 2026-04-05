# =============================================================================
# observability モジュール
#
# 役割:
#   レビューワークフローの異常をいち早く検知するための CloudWatch アラームを設定する。
#
# 監視対象:
#   1. Step Functions: ExecutionsFailed   - ワークフロー全体の失敗
#   2. Step Functions: ExecutionsTimedOut - タイムアウト（60秒 × 7ステート = 最大 7 分）
#   3. Lambda Errors: workflow-starter    - S3 トリガーから SF 起動の失敗
#   4. Lambda Errors: supervisor          - 4 エージェント結果の統合失敗
#
# 通知:
#   alarm_email が設定されている場合のみ SNS サブスクリプション（Email）を作成する。
#   未設定でもアラーム自体は作成され、SNS トピックも存在するため
#   後から AWS コンソールで手動サブスクリプションを追加できる。
# =============================================================================

# =============================================================================
# SNS トピック: アラーム通知先
# =============================================================================
resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms-${var.environment}"
}

# メールアドレスが設定されている場合のみサブスクリプションを作成
# （Terraform apply 後に AWS から確認メールが届くので承認が必要）
resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# =============================================================================
# CloudWatch アラーム: Step Functions
# =============================================================================

# ワークフロー実行の失敗（いずれかのステートが Catch なしで失敗）
resource "aws_cloudwatch_metric_alarm" "sf_executions_failed" {
  alarm_name          = "${var.project_name}-sf-executions-failed-${var.environment}"
  alarm_description   = "Step Functions レビューワークフローの実行失敗を検知します。"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching" # データがない期間はアラームを上げない

  dimensions = {
    StateMachineArn = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.state_machine_name}"
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ワークフロー実行のタイムアウト
resource "aws_cloudwatch_metric_alarm" "sf_executions_timed_out" {
  alarm_name          = "${var.project_name}-sf-executions-timed-out-${var.environment}"
  alarm_description   = "Step Functions レビューワークフローのタイムアウトを検知します。Lambda タイムアウト設定を確認してください。"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsTimedOut"
  namespace           = "AWS/States"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.state_machine_name}"
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# =============================================================================
# CloudWatch アラーム: Lambda
# =============================================================================

# workflow-starter Lambda のエラー（S3 トリガー → SF 起動フェーズ）
resource "aws_cloudwatch_metric_alarm" "workflow_starter_errors" {
  alarm_name          = "${var.project_name}-workflow-starter-errors-${var.environment}"
  alarm_description   = "workflow-starter Lambda のエラーを検知します。S3 イベント → Step Functions 起動が失敗しています。"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.workflow_starter_function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# supervisor Lambda のエラー（4 エージェント結果の統合フェーズ）
resource "aws_cloudwatch_metric_alarm" "supervisor_errors" {
  alarm_name          = "${var.project_name}-supervisor-errors-${var.environment}"
  alarm_description   = "supervisor Lambda のエラーを検知します。4 エージェントの結果統合が失敗しています。"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.supervisor_function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# =============================================================================
# データソース（ARN 構築に使用）
# =============================================================================
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
