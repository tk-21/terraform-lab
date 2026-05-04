locals {
  name_prefix = "${var.prefix}-${var.env}"

  common_tags = {
    ManagedBy   = "terraform"
    Project     = "k8s-idp-lab"
    Environment = var.env
  }
}
