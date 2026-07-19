resource "aws_ecr_repository" "apps" {
  for_each = toset(["api-server", "job-worker"])

  name                 = each.key
  image_tag_mutability = "MUTABLE" # ラボ用: latestタグを上書きして素早くイテレーション
  # 本番: IMMUTABLEでイメージの不変性を保証

  image_scanning_configuration {
    # プッシュ時に脆弱性スキャンを自動実行
    scan_on_push = true
  }

  tags = { Name = each.key }
}

resource "aws_ecr_lifecycle_policy" "apps" {
  for_each   = aws_ecr_repository.apps
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "untaggedイメージを7日後に削除してストレージコストを抑制"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.apps : k => v.repository_url }
}

output "ecr_api_url" {
  value = aws_ecr_repository.apps["api-server"].repository_url
}

output "ecr_worker_url" {
  value = aws_ecr_repository.apps["job-worker"].repository_url
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}
