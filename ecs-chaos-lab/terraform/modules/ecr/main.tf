locals {
  name_prefix = "${var.prefix}-${var.env}"
}

# ECR リポジトリ
resource "aws_ecr_repository" "nginx" {
  name                 = "${local.name_prefix}-nginx"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # プッシュ時に脆弱性スキャンを実施
    scan_on_push = true
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-nginx"
  })
}

# ライフサイクルポリシー (最新 5 世代のみ保持: コスト削減)
resource "aws_ecr_lifecycle_policy" "nginx" {
  repository = aws_ecr_repository.nginx.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "最新5世代のタグなしイメージを保持、それ以前は削除"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# リポジトリポリシー (同一アカウントの ECS タスクのみプル可能)
resource "aws_ecr_repository_policy" "nginx" {
  repository = aws_ecr_repository.nginx.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSTaskPull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      }
    ]
  })
}
