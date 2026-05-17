# Traffic Chaining パターン（Ingress + Egress Inspection）
#
# ① Internet からの Ingress:
#    IGW → [IGW Edge RT] → Firewall Endpoint → Public Subnet（EC2）
#
# ② EC2 からの Egress:
#    EC2（Public Subnet）→ [Public RT] → Firewall Endpoint → IGW → Internet
#
# これを実現するために 3 種類のルートテーブルを用意する：
#   A. IGW Edge RT   : IGW に Edge Association → Public Subnet CIDR → Firewall Endpoint
#   B. Firewall RT   : Firewall Subnet に関連付け → 0.0.0.0/0 → IGW（Firewall 自身は FW を通らない）
#   C. Public RT 更新: 既存の Public RT に 0.0.0.0/0 → Firewall Endpoint を追加

# -------------------------------------------------------------------
# A. IGW Edge Route Table（Ingress 検査の核心）
# -------------------------------------------------------------------
resource "aws_route_table" "igw_rt" {
  # 設計理由: IGW への Edge Association により、インターネットから Public Subnet
  # 宛ての Ingress トラフィックを Firewall Endpoint 経由に強制する。
  # これがないと Ingress 側の検査が行われず、Egress のみの片方向制御になる。
  vpc_id = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-rtb-igw-edge"
  })
}

# IGW から Public Subnet 宛てのトラフィックを Firewall Endpoint 経由にする
resource "aws_route" "igw_to_firewall" {
  # 設計理由: for_each で全 Public Subnet CIDR のルートを生成する。
  # 1AZ 構成のため全 Public Subnet のトラフィックを 1a の Firewall Endpoint に集約する。
  for_each = var.public_subnet_cidrs

  route_table_id         = aws_route_table.igw_rt.id
  destination_cidr_block = each.value
  vpc_endpoint_id        = local.firewall_endpoint_id
}

# IGW に Edge Association でルートテーブルをアタッチ
# subnet_id ではなく gateway_id を使うのが Edge Association の特徴
resource "aws_route_table_association" "igw_edge" {
  gateway_id     = var.internet_gateway_id
  route_table_id = aws_route_table.igw_rt.id
}

# -------------------------------------------------------------------
# B. Firewall Subnet Route Table
# -------------------------------------------------------------------
resource "aws_route_table" "firewall_rt" {
  # 設計理由: Firewall Subnet 自体のトラフィックは直接 IGW へ向ける。
  # Firewall Endpoint を通過してしまうとトラフィックループが発生するため、
  # Firewall Subnet だけは IGW への直接ルートが必要。
  vpc_id = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-rtb-firewall"
  })
}

resource "aws_route" "firewall_to_igw" {
  route_table_id         = aws_route_table.firewall_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = var.internet_gateway_id
}

# Firewall Subnet を専用ルートテーブルに関連付け
# Phase 1 では一時的に private RT に関連付けていたため、ここで上書きする
resource "aws_route_table_association" "firewall" {
  subnet_id      = var.firewall_subnet_id_1a
  route_table_id = aws_route_table.firewall_rt.id
}

# -------------------------------------------------------------------
# C. Public Subnet Route Table — Egress を Firewall Endpoint 経由に変更
# -------------------------------------------------------------------
resource "aws_route" "public_to_firewall" {
  # 設計理由: EC2 からの Egress を IGW 直接ではなく Firewall Endpoint 経由にする。
  # Phase 1 の vpc/main.tf では inline route で 0.0.0.0/0 → IGW を設定していたが、
  # Phase 2 では vpc/main.tf から inline route を削除し、このリソースで管理する。
  # これにより Network Firewall がインターネット向け通信のゲートキーパーになる。
  route_table_id         = var.public_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.firewall_endpoint_id
}
