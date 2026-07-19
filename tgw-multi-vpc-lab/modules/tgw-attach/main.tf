# このアタッチメントが「どのルートテーブルで評価されるか」を決定する。
# Spoke-AのパケットはSpoke RTで評価 → HubへのルートしかないのでSpokeへは届かない。
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = var.route_table_id
}

# このVPCのCIDRを「どのルートテーブルに広告するか」を設定する。
# Spoke-AはHub RTにのみ伝播 → Spoke RTにはHub CIDRだけが残り、Spoke同士の到達性がなくなる。
resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = toset(var.propagate_to_route_table_ids)

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = each.value
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id             = var.vpc_id
  subnet_ids         = var.tgw_subnet_ids

  # デフォルトルートテーブルへの自動関連付け・自動伝播を無効化。
  # Phase3でルートテーブルを手動設計し、SpokeA↔SpokeB禁止などの通信制御を実装するため。
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, { Name = "${var.attachment_name}-attach" })
}
