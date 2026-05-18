locals {
  # 命名プレフィックス: iac-trilogy-lab (itl) + 環境 (dev)
  prefix = "itl-dev"

  # 全リソースに付与する共通タグ
  # CostOwner を入れることで Cost Explorer のフィルタリングが容易になる
  common_tags = {
    Project   = "iac-trilogy-lab"
    Env       = "dev"
    ManagedBy = "terraform"
    CostOwner = "takuya"
  }

  # ネットワーク設定
  # CIDR はインフラ仕様書 (infra-spec.md) と一致させる（3実装共通の正解定義）
  vpc_cidr    = "10.10.0.0/16"
  subnet_cidr = "10.10.1.0/24"
  subnet_az   = "ap-northeast-1a"

  # S3バケット名: 全AWSアカウントでグローバルユニークにするためアカウントIDをサフィックスに使用
  artifacts_bucket_name = "${local.prefix}-artifacts-${var.aws_account_id}"
}
