# =============================================================================
# CloudWatchモジュール
# カスタムメトリクス収集・ログ収集・ダッシュボード・アラームを一元管理する。
# EC2のCloudWatch Agentへの設定配布にSSM Parameter Storeを使用する。
# =============================================================================

# -----------------------------------------------------------------------------
# SSM Parameter Store: CloudWatch Agent設定
# Agent設定をコードで管理し、Ansibleからaws cliで取得してEC2に配布する。
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "cw_agent_config" {
  name  = "/tap/${var.environment}/cloudwatch-agent/config"
  type  = "String"
  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = {
      namespace = "TerraformAnsiblePlatform/${var.environment}"
      # InstanceId をすべてのメトリクスに付与することで、
      # アラームやダッシュボードからインスタンス単位でフィルタできる
      append_dimensions = {
        InstanceId   = "$${aws:InstanceId}"
        InstanceType = "$${aws:InstanceType}"
      }
      metrics_collected = {
        cpu = {
          measurement                 = ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"]
          metrics_collection_interval = 60
          totalcpu                    = true
        }
        mem = {
          measurement = ["mem_used_percent", "mem_available_percent"]
        }
        disk = {
          measurement                 = ["used_percent", "inodes_free"]
          metrics_collection_interval = 60
          resources                   = ["/"]
        }
        net = {
          measurement = ["bytes_sent", "bytes_recv", "packets_sent", "packets_recv"]
          resources   = ["eth0"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path        = "/var/log/nginx/access.log"
              log_group_name   = "/tap/${var.environment}/nginx/access"
              log_stream_name  = "{instance_id}"
              timestamp_format = "%d/%b/%Y:%H:%M:%S %z"
            },
            {
              file_path      = "/var/log/nginx/error.log"
              log_group_name = "/tap/${var.environment}/nginx/error"
              log_stream_name = "{instance_id}"
            },
            {
              file_path      = "/var/log/flask-app.log"
              log_group_name = "/tap/${var.environment}/flask-app"
              log_stream_name = "{instance_id}"
            }
          ]
        }
      }
    }
  })

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# 保持期間を設定してログストレージコストを削減する。
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "nginx_access" {
  name              = "/tap/${var.environment}/nginx/access"
  retention_in_days = 30

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_log_group" "nginx_error" {
  name              = "/tap/${var.environment}/nginx/error"
  retention_in_days = 30

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_log_group" "flask_app" {
  name              = "/tap/${var.environment}/flask-app"
  retention_in_days = 14

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# SNS Topic: アラート通知
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "tap-${var.environment}-alerts"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# CloudWatch Alarms
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "tap-${var.environment}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 80
  alarm_description   = "EC2 CPU使用率が80%を3分間超えた"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  # SEARCH式でnamespace内の全インスタンスを自動検出し平均を監視する。
  # dimensionsをハードコードしないことでインスタンス増減に自動追従する。
  metric_query {
    id          = "cpu_avg"
    expression  = "AVG(SEARCH('Namespace=\"TerraformAnsiblePlatform/${var.environment}\" MetricName=\"cpu_usage_user\" cpu=\"cpu-total\"', 'Average', 60))"
    label       = "CPU Usage Avg (all instances)"
    return_data = true
  }

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "tap-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_description   = "ALBで1分間に5xxエラーが10件を超えた"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "tap-${var.environment}-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "ALB Target Groupにunhealthyなホストが存在する"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    TargetGroup  = var.target_group_arn_suffix
    LoadBalancer = var.alb_arn_suffix
  }

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Dashboard
# ALBメトリクスとEC2カスタムメトリクスを1画面で確認できる統合ダッシュボード。
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "tap-${var.environment}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Request Count"
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount",
              "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Target Response Time (p99)"
          period = 60
          stat   = "p99"
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "EC2 CPU Usage (%)"
          period = 60
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('Namespace=\"TerraformAnsiblePlatform/${var.environment}\" MetricName=\"cpu_usage_user\" cpu=\"cpu-total\"', 'Average', 60)", label = "CPU Usage by Instance", id = "cpu" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Memory Used (%)"
          period = 60
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('Namespace=\"TerraformAnsiblePlatform/${var.environment}\" MetricName=\"mem_used_percent\"', 'Average', 60)", label = "Memory Used by Instance", id = "mem" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "ALB 5XX Errors"
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",
              "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Unhealthy Host Count"
          period = 60
          stat   = "Maximum"
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "UnHealthyHostCount",
              "TargetGroup", var.target_group_arn_suffix,
              "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      }
    ]
  })
}
