# =============================================================
# Spoke-Dev VPC に VPC Endpointを配置
# Prod環境と同構成（学習目的のためポリシーはProdより緩め）
# =============================================================

module "endpoints" {
  source = "../../modules/endpoint"

  prefix   = local.prefix
  vpc_id   = module.vpc.vpc_id
  vpc_cidr = module.vpc.vpc_cidr

  subnet_ids      = module.vpc.private_subnet_ids
  route_table_ids = values(module.vpc.route_table_ids)

  gateway_endpoints = {
    "s3" = {
      policy = null # Dev環境はデフォルト全許可
    }
    "dynamodb" = {
      policy = null
    }
  }

  interface_endpoints = toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
  ])

  tags = local.common_tags
}
