# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name = "containerInsights"
    # Container Insightsを有効化してメトリクスをCloudWatchに送信
    value = "enabled"
  }
}

# Fargate SpotをデフォルトにしてECSコストを削減
# Spotは中断リスクがあるが前処理タスクは冪等設計のため問題なし
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# CloudWatch Logsグループ
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/aip/${var.env}/ecs/preprocessor"
  retention_in_days = 7 # ハンズオンのため短期間保持
}

# ECSタスク定義
resource "aws_ecs_task_definition" "preprocessor" {
  family                   = "${var.name_prefix}-preprocessor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  # arm64(Graviton2)はx86_64比で約20%コスト削減
  cpu    = 256
  memory = 512
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn

  container_definitions = jsonencode([{
    name  = "preprocessor"
    image = "${var.ecr_repository_url}:latest"

    # 環境変数はStep Functionsのステートから上書きされる
    # ここではデフォルト値のみ定義
    environment = [
      { name = "INPUT_BUCKET", value = var.input_bucket_name },
      { name = "OUTPUT_BUCKET", value = var.output_bucket_name },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "preprocessor"
      }
    }

    # ヘルスチェックはバッチタスクのため不要
    essential = true
  }])
}

# ECS前処理タスク用セキュリティグループ
# アウトバウンドのみ開放（VPC Endpoint経由でS3・ECR通信）
resource "aws_security_group" "ecs_task" {
  name        = "${var.name_prefix}-ecs-task-sg"
  description = "ECS前処理タスク用 - アウトバウンドのみ（VPC Endpoint経由でS3通信）"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
