# ECS クラスター
resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name = "containerInsights"
    # Container Insights を有効化してメトリクスを取得
    # CloudWatch エージェントが自動でサイドカー起動する
    value = "enabled"
  }

  tags = { Name = "${var.name_prefix}-cluster" }
}

# CloudWatch ロググループ
resource "aws_cloudwatch_log_group" "app" {
  name = "/ecs/${var.name_prefix}/app"
  # コスト管理のため30日でログを自動削除
  retention_in_days = 30

  tags = { Name = "${var.name_prefix}-logs" }
}

# ECS タスク実行ロール (ECR pull / CloudWatch Logs への書き込み権限)
resource "aws_iam_role" "task_execution" {
  name = "${var.name_prefix}-ecs-task-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role = aws_iam_role.task_execution.name
  # AmazonECSTaskExecutionRolePolicy には ECR read + CloudWatch Logs 書き込みが含まれる
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS タスクロール (アプリが AWS サービスにアクセスする際に使用)
resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# タスク定義
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # Fargate では awsvpc 必須

  # コスト最適: 最小構成 (0.25 vCPU / 0.5 GB)
  cpu    = 256
  memory = 512

  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  # Graviton2 (arm64) を使用してコストを ~20% 削減
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${var.ecr_repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "PORT", value = "8080" },
      { name = "IMAGE_TAG", value = var.image_tag }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
  }])

  tags = { Name = "${var.name_prefix}-taskdef" }
}

# ECS サービス
resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    # ECS タスクはプライベートサブネットに配置
    # インターネット疎通は VPC Endpoint 経由
    subnets          = var.private_subnet_ids
    security_groups  = [var.sg_ecs_task_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.tg_blue_arn
    container_name   = "app"
    container_port   = 8080
  }

  # Blue/Green デプロイのため CodeDeploy コントローラーを使用
  # rolling update だと切り替え中に ALB が新旧タスクに振り分けてしまうため
  deployment_controller {
    type = "CODE_DEPLOY"
  }

  # CodeDeploy がタスク定義とロードバランサーを管理するため
  # Terraform の差分検知から除外する
  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }

}
