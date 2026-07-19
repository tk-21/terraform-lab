# ────────────────────────────────────────────────
# ECR リポジトリ: AI Gateway コンテナイメージ
# ────────────────────────────────────────────────

resource "aws_ecr_repository" "ai_gateway" {
  # AI Gateway (FastAPI) の arm64 イメージを格納する
  # EKS ノードは VPC Endpoint 経由でイメージを Pull するため NAT Gateway 不要
  name                 = "${local.name_prefix}-ai-gateway"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # プッシュ時に脆弱性スキャンを実行してセキュリティリスクを早期検出する
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "ai_gateway" {
  repository = aws_ecr_repository.ai_gateway.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新10イメージのみ保持してストレージコストを削減する"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ────────────────────────────────────────────────
# SSM パラメータ: 時間あたり予算上限
# ────────────────────────────────────────────────

resource "aws_ssm_parameter" "hourly_budget" {
  # AI Gateway が /ai-inference/hourly-budget-usd を参照してルーティングを切り替える
  name  = "/ai-inference/hourly-budget-usd"
  type  = "String"
  value = tostring(var.hourly_budget_usd)

  description = "AI 推論の時間あたりコスト上限 (USD): この値を超えると Bedrock に自動フォールバック"

  tags = local.common_tags
}
