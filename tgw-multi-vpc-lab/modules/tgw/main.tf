resource "aws_ec2_transit_gateway_route_table" "spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-spoke-rt" })
}

# HubとInspectionはここに関連付ける。
# すべてのSpokeのCIDRが伝播で入ってくるため、Spokeへの折り返し通信が可能になる。
resource "aws_ec2_transit_gateway_route_table" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = merge(var.tags, { Name = "${var.name}-hub-rt" })
}

resource "aws_ec2_transit_gateway" "this" {
  description     = var.description
  amazon_side_asn = var.amazon_side_asn

  # デフォルトルートテーブルへの自動関連付けを無効化する。
  # 有効のままだと全アタッチメントが同じルートテーブルに自動登録され、
  # SpokeA↔SpokeB通信禁止などの細かい通信制御ができなくなるため。
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  dns_support      = "enable"
  vpn_ecmp_support = "enable"

  tags = merge(var.tags, { Name = var.name })
}
