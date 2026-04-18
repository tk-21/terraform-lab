data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------
# EventBridge Scheduler 用 IAM ロール
# 権限: analyzer-trigger Lambda の InvokeFunction のみ
# -----------------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
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

  tags = var.tags
}

resource "aws_iam_policy" "scheduler_invoke_lambda" {
  name        = "${var.project_name}-scheduler-invoke-lambda-policy"
  description = "EventBridge Scheduler が analyzer-trigger Lambda を呼び出す最小権限ポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeAnalyzerTriggerLambda"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = var.analyzer_trigger_function_arn
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "scheduler_invoke_lambda" {
  role       = aws_iam_role.scheduler.name
  policy_arn = aws_iam_policy.scheduler_invoke_lambda.arn
}

# -----------------------------------------------------------------------
# EventBridge Scheduler
# スケジュール: cron(0 0 ? * MON *) = 毎週月曜 00:00 UTC = 09:00 JST
# ターゲット: analyzer-trigger Lambda のみ
# -----------------------------------------------------------------------
resource "aws_scheduler_schedule" "weekly_scan" {
  name        = "${var.project_name}-weekly-scan"
  description = "毎週月曜 09:00 JST に IAM 未使用アクセス検出をトリガーする"

  # 毎週月曜 00:00 UTC（= 09:00 JST）に実行
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "UTC"

  # 柔軟な実行ウィンドウなし（指定時刻に厳密に実行）
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = var.analyzer_trigger_function_arn
    role_arn = aws_iam_role.scheduler.arn

    # リトライポリシー: 最大 2 回リトライ、最大 1 時間以内
    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }

  state = "ENABLED"
}

# -----------------------------------------------------------------------
# Lambda リソースベースポリシー: Scheduler からの呼び出しを許可
# -----------------------------------------------------------------------
resource "aws_lambda_permission" "allow_scheduler" {
  statement_id  = "AllowEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = var.analyzer_trigger_function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.weekly_scan.arn
}
