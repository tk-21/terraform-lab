# =============================================================================
# プロバイダーバージョン固定
# archive プロバイダーは Lambda ZIP パッケージ生成に使用
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # 全リソースに共通タグを自動付与（タグ戦略準拠）
  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project_name
      Owner       = var.owner
      CostCenter  = var.cost_center
    }
  }
}
