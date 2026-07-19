terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "hub_vpc" {
  source = "../../modules/vpc"

  vpc_name             = "hub"
  vpc_cidr             = "10.0.0.0/16"
  private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  tgw_subnet_cidrs     = ["10.0.11.0/28", "10.0.11.16/28"]
  tags                 = local.common_tags
}

module "spoke_a_vpc" {
  source = "../../modules/vpc"

  vpc_name             = "spoke-a"
  vpc_cidr             = "10.1.0.0/16"
  private_subnet_cidrs = ["10.1.1.0/24", "10.1.2.0/24"]
  tgw_subnet_cidrs     = ["10.1.11.0/28", "10.1.11.16/28"]
  tags                 = local.common_tags
}

module "spoke_b_vpc" {
  source = "../../modules/vpc"

  vpc_name             = "spoke-b"
  vpc_cidr             = "10.2.0.0/16"
  private_subnet_cidrs = ["10.2.1.0/24", "10.2.2.0/24"]
  tgw_subnet_cidrs     = ["10.2.11.0/28", "10.2.11.16/28"]
  tags                 = local.common_tags
}

module "inspection_vpc" {
  source = "../../modules/vpc"

  vpc_name             = "inspection"
  vpc_cidr             = "10.3.0.0/16"
  private_subnet_cidrs = ["10.3.1.0/24", "10.3.2.0/24"]
  tgw_subnet_cidrs     = ["10.3.11.0/28", "10.3.11.16/28"]
  tags                 = local.common_tags
}

module "tgw" {
  source      = "../../modules/tgw"
  name        = "tgw-${var.project}"
  description = "Transit Gateway for ${var.project}"
  tags        = local.common_tags
}

# Hub RT で評価 → すべてのSpokeへのルートが伝播で入ってくる
# Spoke RT に自分のCIDRを伝播 → SpokeがHubへ戻れるようにする
module "hub_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.hub_vpc.vpc_id
  tgw_subnet_ids  = values(module.hub_vpc.tgw_subnet_ids)
  attachment_name = "hub"

  route_table_id               = module.tgw.hub_route_table_id
  propagate_to_route_table_ids = [module.tgw.spoke_route_table_id]

  tags = local.common_tags
}

# Spoke RT で評価 → Hub CIDRしかないためSpokeへは届かない（通信禁止の実現）
# Hub RT にのみ伝播 → HubがSpoke-AのCIDRを知れるようにする
module "spoke_a_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.spoke_a_vpc.vpc_id
  tgw_subnet_ids  = values(module.spoke_a_vpc.tgw_subnet_ids)
  attachment_name = "spoke-a"

  route_table_id               = module.tgw.spoke_route_table_id
  propagate_to_route_table_ids = [module.tgw.hub_route_table_id]

  tags = local.common_tags
}

module "spoke_b_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.spoke_b_vpc.vpc_id
  tgw_subnet_ids  = values(module.spoke_b_vpc.tgw_subnet_ids)
  attachment_name = "spoke-b"

  route_table_id               = module.tgw.spoke_route_table_id
  propagate_to_route_table_ids = [module.tgw.hub_route_table_id]

  tags = local.common_tags
}

# Hub RT で評価（HubとInspectionは同じルートテーブルで管理）
# Spoke RT に伝播 → Phase4でInspection経由の外部通信を受け取る準備
module "inspection_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.inspection_vpc.vpc_id
  tgw_subnet_ids  = values(module.inspection_vpc.tgw_subnet_ids)
  attachment_name = "inspection"

  route_table_id               = module.tgw.hub_route_table_id
  propagate_to_route_table_ids = [module.tgw.spoke_route_table_id]

  tags = local.common_tags
}

# VPC側ルート: プライベートサブネットから10.0.0.0/8宛の通信をTGW経由にする
# 各VPCのルートテーブルにこのエントリがないと、他VPCへのパケットがローカルで破棄される
resource "aws_route" "spoke_a_to_tgw" {
  for_each = toset(module.spoke_a_vpc.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.tgw_id

  depends_on = [module.spoke_a_attach]
}

resource "aws_route" "spoke_b_to_tgw" {
  for_each = toset(module.spoke_b_vpc.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.tgw_id

  depends_on = [module.spoke_b_attach]
}

resource "aws_route" "hub_to_tgw" {
  for_each = toset(module.hub_vpc.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.tgw_id

  depends_on = [module.hub_attach]
}

resource "aws_route" "inspection_to_tgw" {
  for_each = toset(module.inspection_vpc.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.tgw_id

  depends_on = [module.inspection_attach]
}

# ─────────────────────────────────────────
# Phase 4: 疎通確認用EC2インスタンス
# Hub / Spoke-A / Spoke-B の3VPCに1台ずつ配置
# ─────────────────────────────────────────

module "test_ec2_hub" {
  source        = "../../modules/test-ec2"
  instance_name = "test-hub"
  vpc_id        = module.hub_vpc.vpc_id
  subnet_id     = values(module.hub_vpc.private_subnet_ids)[0]
  tags          = local.common_tags
}

module "test_ec2_spoke_a" {
  source        = "../../modules/test-ec2"
  instance_name = "test-spoke-a"
  vpc_id        = module.spoke_a_vpc.vpc_id
  subnet_id     = values(module.spoke_a_vpc.private_subnet_ids)[0]
  tags          = local.common_tags
}

module "test_ec2_spoke_b" {
  source        = "../../modules/test-ec2"
  instance_name = "test-spoke-b"
  vpc_id        = module.spoke_b_vpc.vpc_id
  subnet_id     = values(module.spoke_b_vpc.private_subnet_ids)[0]
  tags          = local.common_tags
}
