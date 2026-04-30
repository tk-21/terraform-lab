# カスタム前処理ロジックを含むコンテナ。ビルトインイメージで対応できない場合に使用
resource "aws_ecr_repository" "processing" {
  name                 = "${var.prefix}-processing"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.common_tags
}

resource "aws_ecr_lifecycle_policy" "processing" {
  repository = aws_ecr_repository.processing.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "最新10イメージのみ保持"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# カスタム学習ロジックを含むコンテナ。ビルトインイメージで対応できない場合に使用
resource "aws_ecr_repository" "training" {
  name                 = "${var.prefix}-training"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.common_tags
}

resource "aws_ecr_lifecycle_policy" "training" {
  repository = aws_ecr_repository.training.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "最新10イメージのみ保持"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
