locals {
  common_tags = {
    Project     = "vpc-lattice-msk-flink-streaming-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
    CostCenter  = "portfolio"
  }

  name_prefix = "${var.project_name}-${var.environment}"
}
