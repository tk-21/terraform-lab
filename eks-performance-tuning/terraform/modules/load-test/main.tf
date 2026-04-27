terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  common_tags = {
    Project     = "eks-performance-tuning"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  bucket_name   = "${var.project_name}-k6-${var.environment}"
  cluster_name  = "${var.project_name}-load-test-${var.environment}"
  log_group     = "/ecs/${var.project_name}/k6/${var.environment}"
  task_family   = "k6-load-test-${var.environment}"
}

# -----------------------------------------------------------------------------
# S3 Bucket for k6 scripts and results
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "k6" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "k6" {
  bucket = aws_s3_bucket.k6.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "k6" {
  bucket = aws_s3_bucket.k6.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "k6" {
  bucket = aws_s3_bucket.k6.id

  rule {
    id     = "expire-objects"
    status = "Enabled"

    expiration {
      days = 90
    }
  }
}

# -----------------------------------------------------------------------------
# IAM – ECS Task Execution Role
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-k6-task-execution-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# -----------------------------------------------------------------------------
# IAM – ECS Task Role (S3 access)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-k6-task-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "k6_s3" {
  statement {
    sid = "K6S3Access"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.k6.arn,
      "${aws_s3_bucket.k6.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "k6_s3" {
  name   = "k6-s3-access"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.k6_s3.json
}

# -----------------------------------------------------------------------------
# ECS Cluster
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster" "load_test" {
  name = local.cluster_name

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "k6" {
  name              = local.log_group
  retention_in_days = 7

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# ECS Task Definition
# -----------------------------------------------------------------------------

resource "aws_ecs_task_definition" "k6" {
  family                   = local.task_family
  cpu                      = "1024"
  memory                   = "2048"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name  = "k6"
      image = "grafana/k6:0.54.0"
      command = [
        "run",
        "--out",
        "json=/tmp/result.json",
        "/scripts/test.js",
      ]
      environment = [
        {
          name  = "BASE_URL"
          value = var.app_base_url
        },
        {
          name  = "S3_BUCKET"
          value = local.bucket_name
        },
        {
          name  = "SCENARIO"
          value = "default"
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "k6"
        }
      }
      essential = true
    }
  ])

  tags = local.common_tags
}
