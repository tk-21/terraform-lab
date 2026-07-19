locals {
  # 命名計算をここに集約する
  prefix = "${var.project}-${var.env}"

  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# VPC
# =============================================================================

# NAT Gateway は使わない: VPC Endpoint で代替することでコスト削減とセキュリティ向上を両立
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpc" })
}

# =============================================================================
# サブネット (2AZ 構成で高可用性を確保)
# =============================================================================

resource "aws_subnet" "public_1a" {
  # パブリックサブネット: ALB のみ配置し ECS は配置しない
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = "ap-northeast-1a"

  tags = merge(local.common_tags, { Name = "${local.prefix}-public-1a" })
}

resource "aws_subnet" "public_1c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone = "ap-northeast-1c"

  tags = merge(local.common_tags, { Name = "${local.prefix}-public-1c" })
}

resource "aws_subnet" "private_1a" {
  # プライベートサブネット: ECS Fargate タスクはここで動作する
  # NAT Gateway なし: ECR/S3/CloudWatch Logs への通信は VPC Endpoint 経由
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10)
  availability_zone = "ap-northeast-1a"

  tags = merge(local.common_tags, { Name = "${local.prefix}-private-1a" })
}

resource "aws_subnet" "private_1c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11)
  availability_zone = "ap-northeast-1c"

  tags = merge(local.common_tags, { Name = "${local.prefix}-private-1c" })
}

# =============================================================================
# インターネットゲートウェイ (ALB 用)
# =============================================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${local.prefix}-igw" })
}

# パブリックサブネットのルートテーブル: 0.0.0.0/0 → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-rt-public" })
}

resource "aws_route_table_association" "public_1a" {
  subnet_id      = aws_subnet.public_1a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_1c" {
  subnet_id      = aws_subnet.public_1c.id
  route_table_id = aws_route_table.public.id
}

# プライベートサブネット用ルートテーブル (デフォルトルートなし: VPC Endpoint のみ使用)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${local.prefix}-rt-private" })
}

resource "aws_route_table_association" "private_1a" {
  subnet_id      = aws_subnet.private_1a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_1c" {
  subnet_id      = aws_subnet.private_1c.id
  route_table_id = aws_route_table.private.id
}

# =============================================================================
# VPC Endpoint 用セキュリティグループ
# =============================================================================

resource "aws_security_group" "vpc_endpoint" {
  # VPC Endpoint へのインバウンドは VPC CIDR からの HTTPS のみ許可
  name        = "${local.prefix}-sg-vpce"
  description = "VPC Endpoint inbound from VPC CIDR"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from VPC CIDR"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-vpce" })
}

# =============================================================================
# VPC Endpoint (NAT Gateway 代替: プライベートサブネットから AWS サービスへ到達)
# =============================================================================

# ECR API エンドポイント: docker pull 時のマニフェスト取得に使用
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpce-ecr-api" })
}

# ECR DKR エンドポイント: docker pull 時のレイヤーダウンロードに使用
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpce-ecr-dkr" })
}

# S3 Gateway エンドポイント: ECR レイヤーは S3 に保存されているため必須
# Gateway 型は無料 (Interface 型と異なりコストゼロ)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpce-s3" })
}

# CloudWatch Logs エンドポイント: ECS タスクのログ送信に使用
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpce-logs" })
}

# SSM エンドポイント: Parameter Store からシークレットを取得するために使用
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpce-ssm" })
}

# =============================================================================
# セキュリティグループ
# =============================================================================

resource "aws_security_group" "alb" {
  # ALB: インターネットから HTTPS を受け付ける
  # Phase 2 で CloudFront マネージドプレフィックスリストに絞り込む予定
  name        = "${local.prefix}-sg-alb"
  description = "ALB inbound from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet (Phase 2 で CloudFront IP に絞る)"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP from internet (443 へリダイレクト)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-alb" })
}

resource "aws_security_group" "ecs" {
  # ECS: ALB セキュリティグループからのみインバウンドを許可 (ゼロトラスト設計)
  name        = "${local.prefix}-sg-ecs"
  description = "ECS inbound from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "HTTP from ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound (VPC Endpoint 経由で AWS サービスへ到達)"
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-ecs" })
}

# =============================================================================
# ACM 証明書
# =============================================================================

# Route53 ホストゾーン (DNS 検証用)
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ALB 用証明書: ap-northeast-1 で発行
resource "aws_acm_certificate" "alb" {
  domain_name       = "origin.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-acm-alb" })
}

resource "aws_route53_record" "alb_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.alb_cert_validation : record.fqdn]
}

# CloudFront 用証明書: us-east-1 で発行 (CloudFront は us-east-1 の証明書のみ使用可能)
resource "aws_acm_certificate" "cloudfront" {
  provider = aws.use1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-acm-cf" })
}

resource "aws_route53_record" "cf_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.use1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for record in aws_route53_record.cf_cert_validation : record.fqdn]
}

# =============================================================================
# ALB
# =============================================================================

resource "aws_lb" "main" {
  # Internet-facing ALB: パブリックサブネットに配置
  # Phase 2 で SG を CloudFront マネージドプレフィックスリストに絞り込む
  name               = "${local.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_1a.id, aws_subnet.public_1c.id]

  # アクセスログは S3 に保存 (Phase 3 の Athena 分析基盤と統合予定)
  access_logs {
    bucket  = ""
    enabled = false
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-alb" })
}

resource "aws_lb_target_group" "main" {
  # ECS Fargate は IP モードで登録する (awsvpc ネットワークモードのため)
  name        = "${local.prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-tg" })
}

# HTTPS リスナー: ACM 証明書を使用
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# HTTP リスナー: 443 へリダイレクト
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# =============================================================================
# CloudWatch Logs (ECS タスクログ用)
# =============================================================================

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.prefix}-origin"
  retention_in_days = 30

  tags = merge(local.common_tags, { Name = "${local.prefix}-ecs-logs" })
}

# =============================================================================
# IAM (ECS タスク実行ロール)
# =============================================================================

data "aws_iam_policy_document" "ecs_task_exec_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_exec" {
  # IAM ロール名: 64 文字以内 (AWS ハード制限)
  name               = "${local.prefix}-ecs-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_exec_assume.json

  tags = merge(local.common_tags, { Name = "${local.prefix}-ecs-task-exec" })
}

# AWS マネージドポリシーをアタッチ (ECR pull + CloudWatch Logs 書き込み)
resource "aws_iam_role_policy_attachment" "ecs_task_exec_managed" {
  role       = aws_iam_role.ecs_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ecs_task_exec_custom" {
  # ECR からのイメージ取得に必要な最小権限
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability"
    ]
    resources = ["arn:aws:ecr:ap-northeast-1:${data.aws_caller_identity.current.account_id}:repository/*"]
  }

  # ECR 認証トークン取得 (docker login に相当)
  # GetAuthorizationToken は特定リポジトリではなくレジストリ全体に対する操作のため
  # AWS 仕様上 resources = ["*"] が必須。特定 ARN への絞り込みは不可。
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # CloudWatch Logs への構造化ログ送信
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.ecs.arn}:*"]
  }

  # SSM Parameter Store からシークレットを取得 (ハードコード禁止のため)
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    resources = ["arn:aws:ssm:ap-northeast-1:${data.aws_caller_identity.current.account_id}:parameter/${local.prefix}/*"]
  }
}

resource "aws_iam_policy" "ecs_task_exec_custom" {
  name   = "${local.prefix}-ecs-task-exec-custom"
  policy = data.aws_iam_policy_document.ecs_task_exec_custom.json

  tags = merge(local.common_tags, { Name = "${local.prefix}-ecs-task-exec-custom" })
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_custom" {
  role       = aws_iam_role.ecs_task_exec.name
  policy_arn = aws_iam_policy.ecs_task_exec_custom.arn
}

# =============================================================================
# ECS
# =============================================================================

resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-cluster" })
}

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
    base              = 0
  }
}

resource "aws_ecs_task_definition" "origin" {
  family                   = "${local.prefix}-origin"
  cpu                      = 256
  memory                   = 512
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_exec.arn

  # ECS タスクを ARM64 で起動することで Graviton2 の約 20% コスト削減を実現
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "origin"
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = "ap-northeast-1"
          "awslogs-stream-prefix" = "origin"
        }
      }

      # ヘルスチェックエンドポイント: ALB ターゲットグループの health_check path と一致させる
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    }
  ])

  tags = merge(local.common_tags, { Name = "${local.prefix}-origin" })
}

resource "aws_ecs_service" "origin" {
  name            = "${local.prefix}-origin"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.origin.arn
  desired_count   = 2

  # FARGATE_SPOT を主軸にすることで通常 FARGATE 比さらに最大 70% 削減
  # weight=4:1 → 約 80% が Spot で動作 (Spot 中断時は FARGATE にフォールバック)
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
    subnets          = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "origin"
    container_port   = 80
  }

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.ecs_task_exec_managed,
    aws_iam_role_policy_attachment.ecs_task_exec_custom
  ]

  tags = merge(local.common_tags, { Name = "${local.prefix}-origin" })
}
