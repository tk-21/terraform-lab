locals {
  # リソース名の一貫性を保つためプレフィックスをlocalsで集約する
  # 例: "eks-ai-inf-dev" (14文字) → IAM ロール名 64文字制限に余裕を持たせる
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Phase       = "4-gateway"
  }
}
