locals {
  # 共通タグ (versions.tf の default_tags に追加するタグ)
  common_tags = {
    Env = var.env
  }

  # ECR イメージ URI (bootstrap.sh でプッシュ後に参照)
  ecr_image_uri = "${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.prefix}-${var.env}-nginx:latest"
}
