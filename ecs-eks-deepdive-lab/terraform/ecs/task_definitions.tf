# --- API タスク定義 ---
resource "aws_ecs_task_definition" "api" {
  family                   = "deepdive-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  # awsvpc: 各タスクが独立した ENI を持つ、セキュリティグループがタスク単位で適用される
  cpu    = 512
  memory = 1024

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  execution_role_arn = local.execution_role_arn
  task_role_arn      = local.task_role_arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${local.ecr_api_url}:latest"
      essential = true

      portMappings = [
        {
          name          = "api"
          containerPort = 8080
          protocol      = "tcp"
          appProtocol   = "http"
          # appProtocol: Service Connect が HTTP/1.1 レイヤーでルーティングするために必要
        }
      ]

      secrets = [
        {
          name      = "SQS_QUEUE_URL"
          valueFrom = "/deepdive/sqs-queue-url"
        }
      ]

      environment = [
        {
          name  = "AWS_REGION"
          value = "ap-northeast-1"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/deepdive/api"
          "awslogs-region"        = "ap-northeast-1"
          "awslogs-stream-prefix" = "api"
        }
      }

      healthCheck = {
        command = [
          "CMD-SHELL",
          "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8080/health')\" || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      linuxParameters = {
        initProcessEnabled = true
        # PID 1 を init プロセスにすることでゾンビプロセスのリープを防ぐ
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.api]
}

# --- Worker タスク定義 ---
resource "aws_ecs_task_definition" "worker" {
  family                   = "deepdive-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  execution_role_arn = local.execution_role_arn
  task_role_arn      = local.task_role_arn

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = "${local.ecr_worker_url}:latest"
      essential = true

      stopTimeout = 30
      # ECS が SIGTERM を送ってから SIGKILL するまでの待機時間
      # ワーカーはこの 30 秒以内に現在処理中のメッセージを完了させる
      # Fargate の stopTimeout 上限は 120 秒（デフォルト 30 秒）

      secrets = [
        {
          name      = "SQS_QUEUE_URL"
          valueFrom = "/deepdive/sqs-queue-url"
        }
      ]

      environment = [
        {
          name  = "AWS_REGION"
          value = "ap-northeast-1"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/deepdive/worker"
          "awslogs-region"        = "ap-northeast-1"
          "awslogs-stream-prefix" = "worker"
        }
      }

      linuxParameters = {
        initProcessEnabled = true
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.worker]
}
