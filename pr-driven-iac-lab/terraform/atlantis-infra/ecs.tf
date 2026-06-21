# ──────────────────────────────────────────
# CloudWatch Logs
# ──────────────────────────────────────────

resource "aws_cloudwatch_log_group" "atlantis" {
  name              = "/ecs/atlantis"
  retention_in_days = 7

  tags = local.common_tags
}

# ──────────────────────────────────────────
# ECS Cluster
# ──────────────────────────────────────────

resource "aws_ecs_cluster" "atlantis" {
  name = "atlantis-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "atlantis" {
  cluster_name       = aws_ecs_cluster.atlantis.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# ──────────────────────────────────────────
# ECS Task Definition
# ──────────────────────────────────────────

resource "aws_ecs_task_definition" "atlantis" {
  family                   = "atlantis"
  cpu                      = 512
  memory                   = 1024
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  # arm64/Graviton2: x86_64比で約20%コスト削減
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name  = "atlantis"
      image = var.atlantis_image

      portMappings = [
        {
          containerPort = var.atlantis_port
          protocol      = "tcp"
        }
      ]

      # Atlantisの動作設定 (機密情報はsecretsで注入)
      environment = [
        {
          name  = "ATLANTIS_GH_USER"
          value = var.github_repo_owner
        },
        {
          name  = "ATLANTIS_REPO_ALLOWLIST"
          value = "github.com/${var.github_repo_owner}/${var.github_repo_name}"
        },
        {
          name  = "ATLANTIS_PORT"
          value = tostring(var.atlantis_port)
        },
        # ATLANTIS_ATLANTIS_URL はALB作成後に更新が必要
        # apply完了 → alb_dns_name出力値を確認 → この変数を更新 → 再apply
        {
          name  = "ATLANTIS_ATLANTIS_URL"
          value = "http://${aws_lb.atlantis.dns_name}"
        }
      ]

      # GitHubトークンとWebhookシークレットはSSM Parameter Storeから注入
      # 環境変数への直接埋め込みはGit履歴への漏洩リスクがあるため禁止
      secrets = [
        {
          name      = "ATLANTIS_GH_TOKEN"
          valueFrom = "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/atlantis/github-token"
        },
        {
          name      = "ATLANTIS_GH_WEBHOOK_SECRET"
          valueFrom = "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/atlantis/webhook-secret"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.atlantis.name
          awslogs-region        = "ap-northeast-1"
          awslogs-stream-prefix = "ecs"
        }
      }

      essential = true
    }
  ])

  tags = local.common_tags
}

# ──────────────────────────────────────────
# ECS Service
# ──────────────────────────────────────────

resource "aws_ecs_service" "atlantis" {
  name            = "atlantis"
  cluster         = aws_ecs_cluster.atlantis.id
  task_definition = aws_ecs_task_definition.atlantis.arn
  desired_count   = 1

  # FARGATE_SPOT: オンデマンド比で最大70%コスト削減
  # 本番でSLAが必要な場合は FARGATE:base=1 を追加し、スポット中断耐性を確保する
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
    base              = 0
  }

  network_configuration {
    subnets          = [for s in aws_subnet.private : s.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.atlantis.arn
    container_name   = "atlantis"
    container_port   = var.atlantis_port
  }

  # 1台構成のためローリングアップデートなし
  # タスク入れ替え時に一時的にゼロになることを許容する
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [aws_lb_listener.http]

  tags = local.common_tags
}
