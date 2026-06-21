# CodeBuild 用 IAM ロール
resource "aws_iam_role" "codebuild" {
  name = "${var.name_prefix}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${var.name_prefix}-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = var.ecr_repository_arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        # CodeBuild のログは専用プレフィックス配下に限定
        Resource = "arn:aws:logs:*:${var.account_id}:log-group:/aws/codebuild/${var.name_prefix}*"
      },
      {
        Sid    = "S3ArtifactAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${var.artifact_bucket_arn}/*"
      }
    ]
  })
}

# CodeBuild プロジェクト
resource "aws_codebuild_project" "app" {
  name          = "${var.name_prefix}-build"
  description   = "Docker イメージをビルドして ECR に push する"
  build_timeout = 20 # 分 (arm64 buildx は x86 より時間がかかる)
  service_role  = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    # docker buildx を使うため privileged_mode が必要
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # Docker daemon 起動に必要

    environment_variable {
      name  = "REPOSITORY_URI"
      value = var.ecr_repository_url
    }

    environment_variable {
      name  = "CONTAINER_NAME"
      value = "app"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.name_prefix}"
      stream_name = "build"
    }
  }

  tags = { Name = "${var.name_prefix}-codebuild" }
}
