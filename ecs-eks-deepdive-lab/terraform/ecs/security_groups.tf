# ALB Security Group: インターネットからのHTTPのみ受け付ける
resource "aws_security_group" "alb" {
  name        = "deepdive-alb-sg"
  description = "ALB: allow HTTP from internet"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "Forward to ECS tasks on 8080"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = { Name = "deepdive-alb-sg" }
}

# ECS Tasks Security Group: ALBからのトラフィックのみ受け付ける
resource "aws_security_group" "ecs_tasks" {
  name        = "deepdive-ecs-tasks-sg"
  description = "ECS tasks: allow 8080 from ALB only"
  vpc_id      = local.vpc_id

  ingress {
    description     = "App port from ALB only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "HTTPS to AWS services via VPC Endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "deepdive-ecs-tasks-sg" }
}
