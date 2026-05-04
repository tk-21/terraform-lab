locals {
  name_prefix = "${var.prefix}-${var.env}"

  common_tags = merge(var.tags, {
    Environment = var.env
    ManagedBy   = "terraform"
  })
}
