locals {
  name_prefix  = "${var.prefix}-${var.env}"
  cluster_name = "${local.name_prefix}-eks"

  common_tags = merge(var.tags, {
    ManagedBy   = "terraform"
    Project     = var.prefix
    Environment = var.env
  })
}
