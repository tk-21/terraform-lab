# --- API ECS Service ---
resource "aws_ecs_service" "api" {
  name            = "deepdive-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2

  # Capacity Provider 個別指定（cluster default を上書き）
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 4
  }

  # Service Connect: Cloud Map HTTP namespace に登録し、Envoy サイドカーが自動注入される
  # 他サービスから "http://api:8080" でアクセス可能になる
  # Cloud Map DNS と異なり: Retry/Circuit Breaker/メトリクスが無料で使える
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "api" # task_definition の portMappings.name と一致させる
      discovery_name = "api"

      client_alias {
        port     = 8080
        dns_name = "api"
      }
    }

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/deepdive/api"
        "awslogs-region"        = "ap-northeast-1"
        "awslogs-stream-prefix" = "serviceconnect"
      }
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # タスク配置戦略（順序が意味を持つ）
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
    # AZ 障害時の影響を最小化するため、まず AZ に均等分散する
  }
  ordered_placement_strategy {
    type  = "binpack"
    field = "cpu"
    # AZ 内では CPU を詰め込み、タスク密度を上げる
    # Fargate では実質的なコスト影響は少ないが EC2 起動型なら意味が大きい
  }

  # ECS Exec: コンテナ内シェルへのアクセスを有効化
  # 必要 IAM: タスクロールに ssmmessages:* 権限 (Phase 1 で設定済み)
  enable_execute_command = true

  depends_on = [aws_lb_listener.main]
}

# --- Worker ECS Service ---
resource "aws_ecs_service" "worker" {
  name            = "deepdive-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1

  # Worker は全タスクを Spot に振り切る
  # 処理失敗は SQS visibility timeout で自動リトライ、最終的に DLQ に流れる
  # つまり Spot 中断による中断は SQS が吸収してくれる
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 1
  }

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  enable_execute_command = true
}
