# Docker前処理コンテナのイメージリポジトリ
resource "aws_ecr_repository" "preprocessor" {
  name                 = "aip/${var.env}/preprocessor"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # プッシュ時に脆弱性スキャンを自動実行（無料範囲内）
    scan_on_push = true
  }
}

# 古いイメージを自動削除してECRストレージコストを抑制
resource "aws_ecr_lifecycle_policy" "preprocessor" {
  repository = aws_ecr_repository.preprocessor.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新3世代のみ保持"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}
