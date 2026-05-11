# =============================================================
# FIS モジュール
# 実験テンプレートをTerraformで管理することで
# 実験内容をコードとしてレビュー・バージョン管理できる
#
# 安全設計:
# - Stop Condition: CloudWatchアラームでエラー率が閾値超えたら自動停止
# - TargetはTaintで絞り込み（システムノードには絶対触らない）
# - 実験時間に上限（SSMコマンド実験は最大6分: PT6M）
# =============================================================

# --- FIS 実行 IAMロール ---
resource "aws_iam_role" "fis" {
  # IAMロール名はAWSのハード制限64文字に注意
  name = "${var.cluster_name}-fis-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "fis" {
  name = "${var.cluster_name}-fis-policy"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # EC2操作: chaos-targetタグ付きインスタンスのみ許可（最小権限）
      {
        Effect = "Allow"
        Action = [
          "ec2:StopInstances",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/chaos-target" = "true"
          }
        }
      },
      # SSM: Podストレス・ネットワーク遅延注入用
      {
        Effect = "Allow"
        Action = [
          "ssm:StartAutomationExecution",
          "ssm:GetAutomationExecution",
          "ssm:StopAutomationExecution",
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation"
        ]
        Resource = "*"
      },
      # CloudWatch: Stop Condition確認用
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "*"
      },
      # EKS: Pod操作用（クラスター情報取得のみ）
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}"
      },
      # CloudWatch Logs: 実験ログ書き込み先
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/fis/*"
      }
    ]
  })
}

# --- Stop Condition 用 CloudWatch アラーム ---
# ALBの5xxエラー率が1分間に10回超えたらFIS実験を自動停止する
resource "aws_cloudwatch_metric_alarm" "alb_5xx_stop_condition" {
  alarm_name          = "${var.cluster_name}-fis-stop-condition"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "FIS実験停止条件: ALB 5xxエラーが閾値超過"
  treat_missing_data  = "notBreaching"

  tags = var.common_tags
}

# --- FIS ログ用CloudWatch Logsグループ ---
resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/${var.cluster_name}"
  retention_in_days = 30
  tags              = var.common_tags
}

# =====================================================
# 実験1: AZ障害（Cell-A の EC2インスタンスを全停止）
# 検証: Cell-Bへの影響ゼロ・Karpenterの回復時間計測
# =====================================================
resource "aws_fis_experiment_template" "az_outage_cell_a" {
  description = "Cell-A（AZ-a）のEC2インスタンスを停止してKarpenter回復を測定する"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn
  }

  # ターゲット: chaos-cell=cell-a タグ付きEC2インスタンス全台
  target {
    name           = "cell-a-instances"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "chaos-target"
      value = "true"
    }

    resource_tag {
      key   = "chaos-cell"
      value = "cell-a"
    }
  }

  action {
    name      = "stop-cell-a-instances"
    action_id = "aws:ec2:stop-instances"

    target {
      key   = "Instances"
      value = "cell-a-instances"
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = merge(var.common_tags, {
    Name            = "${var.cluster_name}-az-outage-cell-a"
    experiment-type = "az-outage"
  })
}

# =====================================================
# 実験2: Pod CPU ストレス（Cell-A のノードにCPU負荷）
# 検証: HPA・スロットリング・Pod eviction動作
# SSM Run CommandでAWFS提供のストレスドキュメントを実行
# =====================================================
resource "aws_fis_experiment_template" "pod_cpu_stress" {
  description = "Cell-A ノードにCPU負荷をかけてスロットリング動作を確認する"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn
  }

  # Cell-Aの50%のノードに負荷をかけてblast radiusを限定
  target {
    name           = "cell-a-instances-stress"
    resource_type  = "aws:ec2:instance"
    selection_mode = "PERCENT(50)"

    resource_tag {
      key   = "chaos-target"
      value = "true"
    }
    resource_tag {
      key   = "chaos-cell"
      value = "cell-a"
    }
  }

  action {
    name      = "cpu-stress"
    action_id = "aws:ssm:send-command"

    parameter {
      key   = "documentArn"
      value = "arn:aws:ssm:${var.aws_region}::document/AWSFIS-Run-CPU-Stress"
    }

    parameter {
      key = "documentParameters"
      value = jsonencode({
        CPU                 = "0"
        DurationSeconds     = "300"
        InstallDependencies = "True"
      })
    }

    # SSMコマンドのタイムアウト（stressコマンドより長く設定）
    parameter {
      key   = "duration"
      value = "PT6M"
    }

    target {
      key   = "Instances"
      value = "cell-a-instances-stress"
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = merge(var.common_tags, {
    Name            = "${var.cluster_name}-pod-cpu-stress"
    experiment-type = "cpu-stress"
  })
}

# =====================================================
# 実験3: ネットワーク遅延注入（Cell-A → 外部通信に遅延）
# 検証: タイムアウト・Circuit Breaker動作
# SSM Run CommandでLinuxのtcコマンドを使用
# =====================================================
resource "aws_fis_experiment_template" "network_latency" {
  description = "Cell-A ノードに200msの遅延を注入してタイムアウト動作を確認する"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn
  }

  target {
    name           = "cell-a-instances-latency"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "chaos-target"
      value = "true"
    }
    resource_tag {
      key   = "chaos-cell"
      value = "cell-a"
    }
  }

  action {
    name      = "network-latency"
    action_id = "aws:ssm:send-command"

    parameter {
      key   = "documentArn"
      value = "arn:aws:ssm:${var.aws_region}::document/AWSFIS-Run-Network-Latency"
    }

    parameter {
      key = "documentParameters"
      value = jsonencode({
        DelayMilliseconds   = "200"
        JitterMilliseconds  = "50"
        DurationSeconds     = "300"
        Interface           = "eth0"
        InstallDependencies = "True"
      })
    }

    parameter {
      key   = "duration"
      value = "PT6M"
    }

    target {
      key   = "Instances"
      value = "cell-a-instances-latency"
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = merge(var.common_tags, {
    Name            = "${var.cluster_name}-network-latency"
    experiment-type = "network-latency"
  })
}
