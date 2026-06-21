resource "aws_ecr_repository" "app" {
  name                 = "${var.name_prefix}-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # push 時に自動スキャンを実行し、脆弱性を早期検知
    scan_on_push = true
  }

  tags = { Name = "${var.name_prefix}-app" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "最新10イメージのみ保持 — ストレージコスト削減"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
