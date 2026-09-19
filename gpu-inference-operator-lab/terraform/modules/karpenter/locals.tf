locals {
  name_prefix = "${var.prefix}-${var.env}"

  common_tags = merge(var.tags, {
    ManagedBy   = "terraform"
    Project     = var.prefix
    Environment = var.env
  })
}
