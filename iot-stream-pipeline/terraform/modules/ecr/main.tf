# processorとreaderで別リポジトリを作成する
# 理由: デプロイサイクルが異なるため、独立したライフサイクル管理が必要

resource "aws_ecr_repository" "processor" {
  name                 = "${var.project_name}-processor"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # プッシュ時に脆弱性スキャンを実行する
    # 理由: コンテナイメージのセキュリティリスクを早期検出するため
    scan_on_push = true
  }

  tags = {
    Project = var.project_name
    Role    = "Kinesisイベント処理Lambda"
  }
}

resource "aws_ecr_repository" "reader" {
  name                 = "${var.project_name}-reader"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = var.project_name
    Role    = "API Gateway経由のDynamoDB読み取りLambda"
  }
}

# 古いイメージを自動削除するライフサイクルポリシー
# 理由: ECRストレージコストを抑えるため、最新1世代のみ保持する
resource "aws_ecr_lifecycle_policy" "processor" {
  repository = aws_ecr_repository.processor.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新イメージ1件のみ保持"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "reader" {
  repository = aws_ecr_repository.reader.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新イメージ1件のみ保持"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}
