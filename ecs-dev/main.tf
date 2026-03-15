locals {
  tags = {
    Project = var.project
    Env     = var.env
  }
}

module "network" {
  source = "./modules/network"

  name       = "${var.project}-${var.env}"
  aws_region = var.aws_region

  vpc_cidr = "10.0.0.0/16"

  # 例：2AZ（a/c）
  public_subnet_cidrs = {
    a = "10.0.11.0/24"
    c = "10.0.12.0/24"
  }

  private_subnet_cidrs = {
    a = "10.0.21.0/24"
    c = "10.0.22.0/24"
  }

  enable_s3_endpoint = true
  tags               = local.tags
}
