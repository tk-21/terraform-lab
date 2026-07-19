locals {
  # リソース名の一貫性を保つためプレフィックスをlocalsで集約する
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
