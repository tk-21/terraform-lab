locals {
  name_prefix = "${var.prefix}-${var.env}"
}

# ALB セキュリティグループ (インターネット向け HTTP アクセス許可)
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB inbound HTTP from internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb-sg"
  })
}

# ECS Task セキュリティグループ
# Fargate awsvpc モードでは Task に ENI が割り当てられる。
# ALB からのみ通信を許可し、直接アクセスを禁止。
# FIS ネットワーク遮断実験はこの ENI レベルで動作する。
resource "aws_security_group" "ecs_task" {
  name        = "${local.name_prefix}-ecs-task-sg"
  description = "ECS Task inbound from ALB only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # ECR イメージ pull / CloudWatch Logs 送信に必要
  egress {
    description = "Allow all outbound (ECR pull, CloudWatch Logs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-ecs-task-sg"
  })
}
