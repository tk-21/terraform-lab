locals {
  name_prefix = "${var.prefix}-${var.env}"
}

# ── CloudWatch 停止条件アラーム ─────────────────────────────────────────

# CPU が 90% を超えて 10 分継続したら FIS 実験を強制停止する安全弁
resource "aws_cloudwatch_metric_alarm" "stop_condition" {
  alarm_name          = "${local.name_prefix}-fis-cpu-stop-condition"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2 # 5 分 × 2 = 10 分継続
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 90
  alarm_description   = "FIS 実験停止条件: CPU 90% 超過が 10 分継続"
  # アクションなし。FIS がこのアラームを監視して自動停止する。
  treat_missing_data = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-fis-stop-condition" })
}

# ── FIS CloudWatch Logs ロググループ ───────────────────────────────────

resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/${local.name_prefix}-cpu-stress"
  retention_in_days = 30

  tags = merge(var.tags, { Name = "/aws/fis/${local.name_prefix}-cpu-stress" })
}

# ── FIS 実験テンプレート ────────────────────────────────────────────────

# 多層安全弁設計:
# Layer 1: FIS 停止条件（CPU 90% × 10 分でアラームトリガー → 自動停止）
# Layer 2: FIS アクション duration PT5M（5 分で自動終了）
# Layer 3: PERCENT(50) 選択（全インスタンスへの同時注入を防止）
# Layer 4: IAM 最小権限（FIS ロールは SSM SendCommand のみ許可）
resource "aws_fis_experiment_template" "cpu_stress" {
  description = "CPU ストレス負荷による ASG スケールアウト検証"
  role_arn    = var.fis_role_arn

  # 停止条件: CloudWatch アラームが ALARM 状態になったら実験停止
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.stop_condition.arn
  }

  # アクション: SSM ドキュメントで CPU ストレスを注入
  action {
    name      = "cpu-stress"
    action_id = "aws:ssm:send-command"

    parameter {
      key = "documentArn"
      # AWS 提供マネージドドキュメントを使用（カスタム不要）
      value = "arn:aws:ssm:ap-northeast-1::document/AWSFIS-Run-CPU-Stress"
    }
    parameter {
      key = "documentParameters"
      # CPU 全コアに 100% 負荷を 300 秒（5 分）注入
      value = jsonencode({
        CPU             = "0"   # 0 = 全 CPU コア対象
        Workers         = "0"   # 0 = コア数と同数のワーカー
        LoadPercent     = "100" # 100% 負荷
        DurationSeconds = "300" # 5 分間継続
      })
    }
    parameter {
      key   = "duration"
      value = "PT5M" # ISO 8601 形式: 5 分
    }

    # ターゲット: ASG インスタンスの 50% をランダム選択
    target {
      key   = "Instances"
      value = "asg-instances"
    }
  }

  # ターゲット定義: ASG 配下のインスタンス 50% を選択
  target {
    name           = "asg-instances"
    resource_type  = "aws:ec2:instance"
    selection_mode = "PERCENT(50)" # インスタンスの 50% に注入

    # ASG タグでフィルタリング（正しいターゲットのみ選択）
    resource_tag {
      key   = "aws:autoscaling:groupName"
      value = var.asg_name
    }
    resource_tag {
      key   = "Project"
      value = "chaos-engineering-lab"
    }
  }

  # 実験ログ設定
  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-cpu-stress-experiment"
    # このテンプレート ID を run_experiment.sh に設定して実行する
  })
}
