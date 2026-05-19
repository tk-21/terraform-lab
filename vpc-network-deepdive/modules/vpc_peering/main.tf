
# =============================================================
# VPC Peering Connection
# 申請側（requester）と承認側（accepter）は同一AWSアカウント内のため
# auto_accept = true で即時承認。クロスアカウントの場合は別途手順が必要。
# =============================================================
resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.requester_vpc_id # 申請側（Hub）
  peer_vpc_id = var.accepter_vpc_id  # 承認側（Spoke）
  auto_accept = true                 # 同一アカウントのため自動承認

  # DNS解決をPeering越しに有効化
  # → SpokeからHubのInterface EndpointのプライベートDNS名を解決できるようになる
  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-peering"
  })
}

# =============================================================
# 申請側（Hub）ルートテーブルへのルート追加
# Hub → Spoke方向: Spoke CIDRへのトラフィックをPeering経由に向ける
# =============================================================
resource "aws_route" "requester_to_accepter" {
  for_each = var.requester_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.accepter_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# =============================================================
# 承認側（Spoke）ルートテーブルへのルート追加
# Spoke → Hub方向: Hub CIDRへのトラフィックをPeering経由に向ける
# 双方向のルート設定が必要な理由: PeeringはL3接続であり、
# ルートテーブルへの明示的な追記なしには通信できない
# =============================================================
resource "aws_route" "accepter_to_requester" {
  for_each = var.accepter_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.requester_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}
