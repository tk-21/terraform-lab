resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/${var.prefix}-${var.env}"
  retention_in_days = 30

  tags = var.tags
}

# ---------------------------------------------------------------
# シナリオ1: Task 強制停止 → Service 自己回復確認
# ---------------------------------------------------------------
resource "aws_fis_experiment_template" "task_kill" {
  description = "【シナリオ1】ECS Task の強制停止 → Service 自己回復確認"
  role_arn    = var.fis_role_arn

  # 停止条件: RunningTaskCount < 1 が 5 分継続（全 Task 停止 = 実験失敗とみなす）
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = var.stop_condition_task_kill_arn
  }

  action {
    name      = "stop-ecs-tasks"
    action_id = "aws:ecs:stop-task"

    parameter {
      key   = "cluster"
      value = var.cluster_arn
    }

    # PERCENT(100) で全 Task を停止し、Service の自己回復速度を計測する。
    # ECS Service は desired_count=2 を維持しようと即座に新 Task を起動するはず。
    target {
      key   = "Tasks"
      value = "all-running-tasks"
    }
  }

  target {
    name           = "all-running-tasks"
    resource_type  = "aws:ecs:task"
    selection_mode = "PERCENT(100)"

    resource_tag {
      key   = "aws:ecs:clusterName"
      value = var.cluster_name
    }
    resource_tag {
      key   = "aws:ecs:serviceName"
      value = var.service_name
    }
  }

  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = merge(var.tags, {
    Name     = "${var.prefix}-${var.env}-scenario1-task-kill"
    Scenario = "task-kill"
  })
}

# ---------------------------------------------------------------
# シナリオ2: ネットワーク遮断 → ALB Unhealthy 確認
# ---------------------------------------------------------------
resource "aws_fis_experiment_template" "network_disruption" {
  description = "【シナリオ2】ECS Task のネットワーク遮断 → ALB Unhealthy 確認"
  role_arn    = var.fis_role_arn

  # 停止条件: HealthyHostCount = 0 が 3 分継続（全断 = 即座に停止）
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = var.stop_condition_network_arn
  }

  action {
    name = "disrupt-task-network"
    # Fargate Task の ENI に対してインバウンド TCP:80 を遮断する。
    # EC2 の aws:network:disrupt-connectivity とは異なる ECS 専用アクション。
    # awsvpc ネットワークモードが前提（ENI が Task に直接アタッチされているため）。
    action_id = "aws:ecs:task-network-blackhole-port"

    parameter {
      key   = "trafficType"
      value = "ingress" # インバウンドのみ遮断（ALB → Task のトラフィック）
    }
    parameter {
      key   = "port"
      value = "80"
    }
    parameter {
      key   = "protocol"
      value = "tcp"
    }
    parameter {
      key   = "duration"
      value = "PT3M" # 3分間遮断（ALB ヘルスチェック失敗 → Unhealthy を観測）
    }

    # 全 Task を遮断すると完全断になるため 50% に絞る。
    # 残り 50% は正常稼働し、ALB が Unhealthy Task を切り離す動作を確認する。
    target {
      key   = "Tasks"
      value = "running-tasks-50pct"
    }
  }

  target {
    name           = "running-tasks-50pct"
    resource_type  = "aws:ecs:task"
    selection_mode = "PERCENT(50)"

    resource_tag {
      key   = "aws:ecs:clusterName"
      value = var.cluster_name
    }
    resource_tag {
      key   = "aws:ecs:serviceName"
      value = var.service_name
    }
  }

  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = merge(var.tags, {
    Name     = "${var.prefix}-${var.env}-scenario2-network"
    Scenario = "network-disruption"
  })
}

# ---------------------------------------------------------------
# シナリオ3: DesiredCount=0 による全 Task 停止 → 手動復旧確認
# ---------------------------------------------------------------
resource "aws_fis_experiment_template" "desired_zero" {
  description = "【シナリオ3】ECS DesiredCount=0 による全 Task 停止 → 手動復旧確認"
  role_arn    = var.fis_role_arn

  # DesiredCount=0 は意図的なゼロスケールのため FIS 停止条件は設定しない。
  # 実験者が手動で restore アクション（Lambda 経由）を実行して復旧を確認する。
  stop_condition {
    source = "none"
  }

  action {
    name = "set-desired-count-zero"
    # FIS ネイティブには ECS DesiredCount 変更アクションがないため
    # Lambda を FIS アクションとして使用する（aws:lambda:invoke）。
    action_id = "aws:lambda:invoke"

    parameter {
      key   = "functionArn"
      value = aws_lambda_function.desired_count_changer.arn
    }
    parameter {
      key = "payload"
      # {"action": "set_zero"} を Base64 エンコード
      value = base64encode(jsonencode({ action = "set_zero" }))
    }
    parameter {
      key   = "invocationType"
      value = "sync" # 同期実行（結果を FIS ログに記録）
    }
  }

  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = merge(var.tags, {
    Name     = "${var.prefix}-${var.env}-scenario3-desired-zero"
    Scenario = "desired-zero"
  })
}
