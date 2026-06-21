# ─── CloudWatch Alarms ──────────────────────────────────────────

# ECS タスク数が 0 になったら即アラーム (サービス障害検知)
# treat_missing_data = "breaching": データなし = タスクなし として評価する
# Container Insights が停止した場合もサービス障害として扱うため
resource "aws_cloudwatch_metric_alarm" "ecs_running_tasks" {
  alarm_name          = "${var.name_prefix}-ecs-no-running-tasks"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "ECS サービスの実行中タスクが 0 になった — サービスダウンの可能性"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions    = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  tags = { Name = "${var.name_prefix}-alarm-ecs-tasks" }
}

# ALB 5xx エラー率アラーム (デプロイ失敗の早期検知)
# Blue/Green デプロイ切り替え直後に 5xx が急増した場合はロールバックを検討する
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-high-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB 5xx エラーが急増 — Blue/Green デプロイ失敗の可能性"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  tags = { Name = "${var.name_prefix}-alarm-alb-5xx" }
}

# ─── EventBridge: CodePipeline 失敗検知 ─────────────────────────

# CloudWatch Alarm では CodePipeline の失敗メトリクスが存在しないため
# EventBridge でステージ失敗イベントを直接捕捉する
resource "aws_cloudwatch_event_rule" "pipeline_failure" {
  name        = "${var.name_prefix}-pipeline-failure"
  description = "CodePipeline のステージ失敗を検知"

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Stage Execution State Change"]
    detail = {
      state    = ["FAILED"]
      pipeline = [var.pipeline_name]
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline_failure_log" {
  rule      = aws_cloudwatch_event_rule.pipeline_failure.name
  target_id = "PipelineFailureLog"
  arn       = aws_cloudwatch_log_group.events.arn
}

# EventBridge から CloudWatch Logs へ書き込む権限を付与する
resource "aws_cloudwatch_log_resource_policy" "events" {
  policy_name = "${var.name_prefix}-eventbridge-log-policy"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action = [
        "logs:CreateLogEvents",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.events.arn}:*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "events" {
  name              = "/aws/events/${var.name_prefix}/pipeline"
  retention_in_days = 30
  tags              = { Name = "${var.name_prefix}-pipeline-events" }
}

# ─── CloudWatch Dashboard ────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# ${var.name_prefix} — CI/CD パイプライン ダッシュボード"
        }
      },
      # Container Insights が有効な場合のみ RunningTaskCount が取得できる
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "ECS 実行中タスク数"
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [[
            "ECS/ContainerInsights", "RunningTaskCount",
            "ClusterName", var.ecs_cluster_name,
            "ServiceName", var.ecs_service_name
          ]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "ALB HTTPレスポンスコード"
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_4XX_Count", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      # p99 レイテンシは外れ値を含む最悪ケースを把握するために有効
      {
        type   = "metric"
        x      = 16
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "ALB レイテンシ (p99)"
          view   = "timeSeries"
          stat   = "p99"
          period = 60
          metrics = [[
            "AWS/ApplicationELB", "TargetResponseTime",
            "LoadBalancer", var.alb_arn_suffix
          ]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 12
        height = 6
        properties = {
          title  = "CodeBuild ビルド時間 (秒)"
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [[
            "AWS/CodeBuild", "Duration",
            "ProjectName", var.codebuild_project_name,
            "BuildStatus", "SUCCEEDED"
          ]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 12
        height = 6
        properties = {
          title  = "ECS CPU / メモリ使用率 (%)"
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["ECS/ContainerInsights", "CpuUtilized", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name],
            ["ECS/ContainerInsights", "MemoryUtilized", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name]
          ]
        }
      }
    ]
  })
}
