# ---- ECR リポジトリ ----

resource "aws_ecr_repository" "payment_processor" {
  name                 = "${var.project}/payment-processor"
  image_tag_mutability = "MUTABLE"

  # なぜ: 脆弱性スキャンを自動化し、セキュリティリスクを可視化
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.common_tags, { Name = "${var.project}-payment-processor" })
}

# なぜ: 古いイメージを自動削除してストレージコストを抑制
resource "aws_ecr_lifecycle_policy" "payment_processor" {
  repository = aws_ecr_repository.payment_processor.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新 5世代のみ保持"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ---- ECS Cluster ----

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  # なぜ: Container Insights で CPU/Memory/Task メトリクスを自動収集
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.common_tags, { Name = "${var.project}-cluster" })
}

# なぜ: FARGATE_SPOT を使うことでコストを最大 70% 削減
#       中断される可能性があるが、決済処理は Step Functions でリトライ可能
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 80
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 20
    base              = 1
  }
}

# ---- IAM: タスク実行ロール (ECR pull / CloudWatch Logs) ----

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.common_tags
}

data "aws_iam_policy_document" "ecs_execution" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = ["*"] # GetAuthorizationToken はリソース指定不可
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.payment_processor.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ecs_execution" {
  name   = "${var.project}-ecs-execution-policy"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution.json
}

# ---- IAM: タスクロール (アプリ用 — DynamoDB / X-Ray) ----

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.common_tags
}

data "aws_iam_policy_document" "ecs_task" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
    ]
    resources = [var.dynamodb_table_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_task" {
  name   = "${var.project}-ecs-task-policy"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task.json
}

# ---- CloudWatch Log Group ----

resource "aws_cloudwatch_log_group" "payment_processor" {
  name              = "/ecs/${var.project}/payment-processor"
  retention_in_days = 7 # なぜ: コスト抑制のため保持期間を短縮

  tags = var.common_tags
}

# ---- Security Group (ECS タスク用) ----

resource "aws_security_group" "ecs_task" {
  name        = "${var.project}-ecs-task-sg"
  description = "ECS payment-processor task SG"
  vpc_id      = var.vpc_id

  # なぜ: Egress 443 のみ許可。VPC Endpoint 経由で DynamoDB/ECR/CloudWatch にアクセス
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS to VPC Endpoints"
  }

  tags = merge(var.common_tags, { Name = "${var.project}-ecs-task-sg" })
}

# ---- ECS Task Definition ----

resource "aws_ecs_task_definition" "payment_processor" {
  family                   = "${var.project}-payment-processor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # なぜ: arm64 で Graviton2 を使用、x86_64 比でコスト約 20% 削減
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  # なぜ: 最小構成から始める。決済処理は CPU より IO 待ちが多いため
  cpu    = 256
  memory = 512

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "payment-processor"
    image = "${aws_ecr_repository.payment_processor.repository_url}:latest"

    # なぜ: 環境変数は Step Functions から ECS RunTask 時に上書きされる
    #       ここはデフォルト値として設定
    environment = [
      { name = "DYNAMODB_TABLE_NAME", value = var.dynamodb_table_name },
      { name = "AWS_REGION", value = "ap-northeast-1" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/${var.project}/payment-processor"
        awslogs-region        = "ap-northeast-1"
        awslogs-stream-prefix = "ecs"
      }
    }

    # なぜ: 非 root ユーザーで実行 (Dockerfile の USER appuser と対応)
    user = "appuser"
  }])

  tags = merge(var.common_tags, { Name = "${var.project}-payment-processor" })
}
