locals {
  name_prefix = "${var.prefix}-${var.env}"
}

# ─────────────────────────────────────────────
# CloudWatch Logs グループ
# ECS コンテナログの保持先。FIS 実験中の Task 停止ログも記録される。
# ─────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name = "/ecs/${local.name_prefix}"
  })
}

# ─────────────────────────────────────────────
# ECS Cluster
# ─────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name = "containerInsights"
    # Container Insights を有効化。FIS 実験中の CPU/Memory/Task 数を可視化。
    value = "enabled"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-cluster"
  })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ─────────────────────────────────────────────
# Task Definition
# ─────────────────────────────────────────────
resource "aws_ecs_task_definition" "main" {
  family                   = "${local.name_prefix}-task"
  requires_compatibilities = ["FARGATE"]
  # awsvpc モードにより各 Task に ENI が割り当てられる。
  # FIS のネットワーク遮断（シナリオ2）はこの ENI を対象に動作する。
  network_mode       = "awsvpc"
  cpu                = var.task_cpu
  memory             = var.task_memory
  execution_role_arn = var.task_execution_role_arn
  task_role_arn      = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = "${var.prefix}-nginx"
      image     = var.ecr_image_uri
      essential = true
      cpu       = var.task_cpu
      memory    = var.task_memory

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost/health || exit 1"]
        interval    = 10
        timeout     = 3
        retries     = 3
        startPeriod = 30
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "nginx"
        }
      }
    }
  ])

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-task"
  })
}

# ─────────────────────────────────────────────
# ECS Service
# ─────────────────────────────────────────────
resource "aws_ecs_service" "main" {
  name            = "${local.name_prefix}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # FIS 実験のトラブルシューティング用（本番では false に設定）
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_task_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "${var.prefix}-nginx"
    container_port   = var.container_port
  }

  # FIS Task Kill 実験後の自動復旧を妨げないよう
  # deployment_minimum_healthy_percent を 50 に設定（Task 数 2 の場合 1台で継続）
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  lifecycle {
    # FIS 実験でシナリオ3（Desired Count 変更）を実行した後、
    # Terraform が desired_count を上書きしないよう ignore_changes に追加。
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-service"
  })

  depends_on = [aws_cloudwatch_log_group.ecs]
}

# ─────────────────────────────────────────────
# CloudWatch アラーム（FIS 停止条件用）
# ─────────────────────────────────────────────

# シナリオ1 停止条件: 実行中 Task が 1 未満になった状態が 5 分継続
resource "aws_cloudwatch_metric_alarm" "running_task_count_low" {
  alarm_name          = "${local.name_prefix}-fis-stop-running-task-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "FIS停止条件: RunningTaskCount が 1 未満（全Task停止）"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.main.name
  }

  tags = var.tags
}

# シナリオ2 停止条件: ALB Healthy Host が 0 になった状態が 3 分継続
resource "aws_cloudwatch_metric_alarm" "healthy_host_count_zero" {
  alarm_name          = "${local.name_prefix}-fis-stop-healthy-host-zero"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 180
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "FIS停止条件: ALB の Healthy Host が 0（全断）"

  dimensions = {
    TargetGroup  = var.target_group_arn_suffix
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}
