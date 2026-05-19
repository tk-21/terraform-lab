
# =============================================================
# Spoke側のTerraform stateからoutputsを参照
# Spokeは別ディレクトリで管理されているため、
# terraform_remote_state でoutputsを読み取る
# =============================================================
data "terraform_remote_state" "spoke_prod" {
  backend = "local"
  config = {
    path = "${path.module}/../../spoke_prod/terraform.tfstate"
  }
}

data "terraform_remote_state" "spoke_dev" {
  backend = "local"
  config = {
    path = "${path.module}/../../spoke_dev/terraform.tfstate"
  }
}

# =============================================================
# Hub ↔ Spoke-Prod Peering
# =============================================================
module "peering_hub_to_prod" {
  source = "../../modules/vpc_peering"

  name_prefix = "vnd-hub-to-prod"

  # Hub側（申請者）
  requester_vpc_id          = module.vpc.vpc_id
  requester_vpc_cidr        = module.vpc.vpc_cidr
  requester_route_table_ids = module.vpc.route_table_ids

  # Spoke-Prod側（承認者）
  accepter_vpc_id          = data.terraform_remote_state.spoke_prod.outputs.vpc_id
  accepter_vpc_cidr        = data.terraform_remote_state.spoke_prod.outputs.vpc_cidr
  accepter_route_table_ids = data.terraform_remote_state.spoke_prod.outputs.route_table_ids

  tags = local.common_tags
}

# =============================================================
# Hub ↔ Spoke-Dev Peering
# =============================================================
module "peering_hub_to_dev" {
  source = "../../modules/vpc_peering"

  name_prefix = "vnd-hub-to-dev"

  requester_vpc_id          = module.vpc.vpc_id
  requester_vpc_cidr        = module.vpc.vpc_cidr
  requester_route_table_ids = module.vpc.route_table_ids

  accepter_vpc_id          = data.terraform_remote_state.spoke_dev.outputs.vpc_id
  accepter_vpc_cidr        = data.terraform_remote_state.spoke_dev.outputs.vpc_cidr
  accepter_route_table_ids = data.terraform_remote_state.spoke_dev.outputs.route_table_ids

  tags = local.common_tags
}

# =============================================================
# ⚠️ Spoke-Prod ↔ Spoke-Dev のPeeringは意図的に作成しない
# 理由: Spoke間通信はHub経由でも不可（PeeringはTransitiveでない）
# この制約こそがHub-Spoke + Peeringの本質的な限界であり、
# TGWが必要になる理由（ADR-002参照）
# =============================================================
