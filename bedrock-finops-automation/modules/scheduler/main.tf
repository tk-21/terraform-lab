# ============================================================
# modules/scheduler
# EventBridge スケジュールルール（毎月1日 09:00 JST に Step Functions を起動）
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# IAM Role - EventBridge → Step Functions 起動用
# ============================================================

resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-scheduler-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# IAM Policy: 対象ステートマシンの StartExecution のみ許可
resource "aws_iam_role_policy" "scheduler" {
  name = "${var.project_name}-scheduler-policy-${var.environment}"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartStateMachineExecution"
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = [var.state_machine_arn]
      }
    ]
  })
}

# ============================================================
# EventBridge Rule - 月次スケジュール
# ============================================================

resource "aws_cloudwatch_event_rule" "monthly_trigger" {
  name        = "${var.project_name}-monthly-trigger-${var.environment}"
  description = "毎月1日 00:00 UTC（= 09:00 JST）に FinOps レポート生成ワークフローを起動する"

  # cron(分 時 日 月 曜日 年)
  # cron(0 0 1 * ? *) = 毎月1日 00:00 UTC
  # "?" は day-of-week に使用（day-of-month を指定する場合は曜日に ? が必要）
  schedule_expression = var.schedule_expression

  state = var.enabled ? "ENABLED" : "DISABLED"
}

# ============================================================
# EventBridge Target - Step Functions ステートマシン
# ============================================================

resource "aws_cloudwatch_event_target" "state_machine" {
  rule      = aws_cloudwatch_event_rule.monthly_trigger.name
  target_id = "FinOpsWorkflow"
  arn       = var.state_machine_arn
  role_arn  = aws_iam_role.scheduler.arn

  # ステートマシンへの初期入力（Lambda の event として渡される）
  # target_year_month を省略すると collector が自動的に前月を対象にする
  input = jsonencode({
    source      = "eventbridge-scheduler"
    description = "Monthly FinOps report triggered by EventBridge"
  })

  # 同一イベントが重複配信された場合の de-duplication（ECS や Lambda 等と同様）
  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600 # 1時間以上古いイベントは破棄（翌月集計に誤影響防止）
  }

  # dead_letter_config は Week4（監視強化フェーズ）で SQS DLQ とともに追加予定
}
