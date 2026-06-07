# =============================================================
# ECS Fargate アプリケーション構成
#
# 設計判断:
# - FARGATE_SPOT でコスト最適化（Spot 中断時の再接続は RDS Proxy が吸収）
# - arm64 (Graviton2): 同等性能で x86_64 比 ~20% コスト削減
# - パスワードを一切環境変数に渡さず IAM 認証トークンで接続
# - ALB → ECS の SG チェーンで最小権限ネットワーク制御
# =============================================================

locals {
  # ECR URI が未指定の場合はリポジトリ作成後に :latest タグを使用
  # 初回 apply では image pull に失敗するが infrastructure は作成される
  effective_image_uri = var.ecr_image_uri != "" ? var.ecr_image_uri : "${aws_ecr_repository.app.repository_url}:latest"
}

# ─── ECR リポジトリ ────────────────────────────────────────────
resource "aws_ecr_repository" "app" {
  name                 = "${var.prefix}-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.prefix}-app" }
}

# ─── セキュリティグループ: ALB ────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.prefix}-alb-sg"
  description = "ALB 用 SG - インターネットからの HTTP を許可"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "インターネットからの HTTP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-alb-sg" }
}

# ─── セキュリティグループ: ECS App ────────────────────────────
resource "aws_security_group" "app" {
  name        = "${var.prefix}-app-sg"
  description = "ECS Fargate タスク用 SG"
  vpc_id      = var.vpc_id

  # ALB からのトラフィックのみ受け入れる
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "ALB からのアプリトラフィック"
  }

  # RDS Proxy への接続（IAM 認証トークンを使用）
  egress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.proxy_sg_id]
    description     = "RDS Proxy への PostgreSQL 接続"
  }

  # VPC Endpoint 経由の AWS API 呼び出し（SSM, ECR, CloudWatch Logs）
  egress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.vpc_endpoint_sg_id]
    description     = "VPC Endpoint 経由の AWS API"
  }

  tags = { Name = "${var.prefix}-app-sg" }
}

# RDS Proxy SG に app SG からのインバウンドを追加
# rds-proxy モジュールで CIDR ベースのルールが既存だが SG ベースも追加して明示的に管理
resource "aws_security_group_rule" "proxy_from_app" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = var.proxy_sg_id
  description              = "ECS App SG からの接続（IAM 認証）"
}

# VPC Endpoint SG に app SG からのインバウンドを追加
resource "aws_security_group_rule" "vpc_endpoint_from_app" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = var.vpc_endpoint_sg_id
  description              = "ECS App SG からの HTTPS（VPC Endpoint 用）"
}

# ─── ALB ─────────────────────────────────────────────────────
resource "aws_lb" "app" {
  name               = "${var.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  tags = { Name = "${var.prefix}-alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.prefix}-app-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip" # Fargate は IP ターゲット
  vpc_id      = var.vpc_id

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  tags = { Name = "${var.prefix}-app-tg" }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ─── ECS Cluster ─────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.prefix}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4 # 80% を SPOT
    base              = 0
  }
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1 # 20% をオンデマンド
    base              = 1 # 最低 1 タスクは FARGATE 保証
  }
}

# ─── IAM: Task Execution Role（ECR/CloudWatch アクセス）──────
resource "aws_iam_role" "task_execution" {
  name = "${var.prefix}-ecs-exec-role"

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
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ─── IAM: Task Role（アプリが使う権限: RDS Proxy + SSM）──────
resource "aws_iam_role" "task" {
  name = "${var.prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# RDS Proxy IAM 認証権限（Phase 3 で作成したポリシー）
resource "aws_iam_role_policy_attachment" "task_rds" {
  role       = aws_iam_role.task.name
  policy_arn = var.app_rds_connect_policy_arn
}

# SSM Parameter Store 読み取り（プロキシエンドポイント・DB 名の取得）
resource "aws_iam_role_policy" "task_ssm" {
  name = "${var.prefix}-task-ssm-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GetSSMParameters"
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/arpl/*"
      ]
    }]
  })
}

# ─── CloudWatch Logs ──────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.prefix}-app"
  retention_in_days = 7
}

# ─── ECS Task Definition ──────────────────────────────────────
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # 0.25 vCPU
  memory                   = 512 # 512 MB
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Graviton2 指定
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = local.effective_image_uri
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    # パスワード系は一切渡さない
    # エンドポイントは SSM から取得し、IAM 認証トークンはコード内で生成する
    environment = [
      { name = "PROXY_ENDPOINT_PARAM", value = "/arpl/rds-proxy/endpoint" },
      { name = "DB_NAME_PARAM", value = "/arpl/rds/db-name" },
      { name = "DB_USER", value = "appuser" },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "LOG_LEVEL", value = "INFO" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60 # 起動直後の DB 初期化時間を考慮
    }
  }])
}

# ─── ECS Service ─────────────────────────────────────────────
resource "aws_ecs_service" "app" {
  name            = "${var.prefix}-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2 # 2 AZ に分散

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4
    base              = 0
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = var.private_app_subnet_ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }

  # ローリングデプロイ: 最低 50% を維持しながら最大 200% まで増やして切り替え
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener.app]
}

# ─── GitHub Actions OIDC ──────────────────────────────────────
# アクセスキー不要で GitHub Actions から ECS デプロイを可能にする
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  # IAMロール名 64 文字制限: arpl-github-actions-role = 26 文字
  name = "${var.prefix}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${var.prefix}-github-actions-deploy-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        # GetAuthorizationToken はリソース指定不可のため * を使用
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid    = "ECSUpdateService"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
        ]
        Resource = aws_ecs_service.app.id
      },
      {
        Sid    = "ECSPassTaskRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.task_execution.arn,
          aws_iam_role.task.arn,
        ]
      },
    ]
  })
}
