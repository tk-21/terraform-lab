locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = "global-accelerator-firehose-databrew-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
    CostCenter  = "portfolio"
  }
}
