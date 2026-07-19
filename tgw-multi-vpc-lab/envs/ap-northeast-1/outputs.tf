output "hub_vpc_id" {
  description = "Hub VPCのID"
  value       = module.hub_vpc.vpc_id
}

output "hub_tgw_subnet_ids" {
  description = "Hub VPCのTGW専用サブネットIDs"
  value       = module.hub_vpc.tgw_subnet_ids
}

output "spoke_a_vpc_id" {
  description = "Spoke-A VPCのID"
  value       = module.spoke_a_vpc.vpc_id
}

output "spoke_a_tgw_subnet_ids" {
  description = "Spoke-A VPCのTGW専用サブネットIDs"
  value       = module.spoke_a_vpc.tgw_subnet_ids
}

output "spoke_b_vpc_id" {
  description = "Spoke-B VPCのID"
  value       = module.spoke_b_vpc.vpc_id
}

output "spoke_b_tgw_subnet_ids" {
  description = "Spoke-B VPCのTGW専用サブネットIDs"
  value       = module.spoke_b_vpc.tgw_subnet_ids
}

output "inspection_vpc_id" {
  description = "Inspection VPCのID"
  value       = module.inspection_vpc.vpc_id
}

output "inspection_tgw_subnet_ids" {
  description = "Inspection VPCのTGW専用サブネットIDs"
  value       = module.inspection_vpc.tgw_subnet_ids
}

output "hub_private_route_table_ids" {
  description = "Hub VPCのプライベートルートテーブルIDs（Phase2でTGWルート追加に使用）"
  value       = module.hub_vpc.private_route_table_ids
}

output "spoke_a_private_route_table_ids" {
  description = "Spoke-A VPCのプライベートルートテーブルIDs"
  value       = module.spoke_a_vpc.private_route_table_ids
}

output "spoke_b_private_route_table_ids" {
  description = "Spoke-B VPCのプライベートルートテーブルIDs"
  value       = module.spoke_b_vpc.private_route_table_ids
}

output "inspection_private_route_table_ids" {
  description = "Inspection VPCのプライベートルートテーブルIDs"
  value       = module.inspection_vpc.private_route_table_ids
}

output "tgw_id" {
  description = "Transit GatewayのID（完了確認コマンドおよびPhase3で使用）"
  value       = module.tgw.tgw_id
}

output "tgw_arn" {
  description = "Transit GatewayのARN"
  value       = module.tgw.tgw_arn
}

output "spoke_route_table_id" {
  description = "Spoke用TGWルートテーブルID（完了確認コマンドで使用）"
  value       = module.tgw.spoke_route_table_id
}

output "hub_route_table_id" {
  description = "Hub/Inspection用TGWルートテーブルID（完了確認コマンドで使用）"
  value       = module.tgw.hub_route_table_id
}

output "hub_attachment_id" {
  description = "Hub VPCアタッチメントID（Phase3でルートテーブル関連付けに使用）"
  value       = module.hub_attach.attachment_id
}

output "spoke_a_attachment_id" {
  description = "Spoke-A VPCアタッチメントID"
  value       = module.spoke_a_attach.attachment_id
}

output "spoke_b_attachment_id" {
  description = "Spoke-B VPCアタッチメントID"
  value       = module.spoke_b_attach.attachment_id
}

output "inspection_attachment_id" {
  description = "Inspection VPCアタッチメントID"
  value       = module.inspection_attach.attachment_id
}

# ─────────────────────────────────────────
# Phase 4: 疎通確認スクリプト用output
# ─────────────────────────────────────────

output "test_hub_instance_id" {
  description = "Hub EC2インスタンスID"
  value       = module.test_ec2_hub.instance_id
}

output "test_hub_private_ip" {
  description = "Hub EC2のプライベートIP"
  value       = module.test_ec2_hub.private_ip
}

output "test_spoke_a_instance_id" {
  description = "Spoke-A EC2インスタンスID（SSM send-commandのsourceに使用）"
  value       = module.test_ec2_spoke_a.instance_id
}

output "test_spoke_a_private_ip" {
  description = "Spoke-A EC2のプライベートIP"
  value       = module.test_ec2_spoke_a.private_ip
}

output "test_spoke_b_instance_id" {
  description = "Spoke-B EC2インスタンスID"
  value       = module.test_ec2_spoke_b.instance_id
}

output "test_spoke_b_private_ip" {
  description = "Spoke-B EC2のプライベートIP（Spoke-A → Spoke-B 遮断確認に使用）"
  value       = module.test_ec2_spoke_b.private_ip
}
