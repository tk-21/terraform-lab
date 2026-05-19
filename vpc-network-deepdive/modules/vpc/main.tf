
# =============================================================
# VPC本体
# enable_dns_hostnames: Interface Endpointの名前解決に必須
# enable_dns_support: VPC内DNSリゾルバ（169.254.169.253）を有効化
# =============================================================
resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.prefix}-vpc"
  })
}

# =============================================================
# サブネット
# var.subnets = { "private-1a" = { cidr = "...", az = "..." }, ... }
# for_eachで複数サブネットを一括作成
# =============================================================
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  # SpokeのプライベートサブネットではパブリックIP不要
  map_public_ip_on_launch = lookup(each.value, "public", false)

  tags = merge(var.tags, {
    Name = "${var.prefix}-${each.key}-subnet"
    Tier = split("-", each.key)[0] # "private" or "public"
  })
}

# =============================================================
# Internet Gateway
# Hubのpublicサブネット用（現フェーズでは未アタッチだが将来拡張用）
# var.create_igw = false の場合はスキップ
# =============================================================
resource "aws_internet_gateway" "this" {
  count  = var.create_igw ? 1 : 0
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.prefix}-igw"
  })
}

# =============================================================
# ルートテーブル（tierごとに1つ）
# public-rtb / private-rtb を分離することでアクセス制御を明確化
# =============================================================
resource "aws_route_table" "this" {
  for_each = toset(distinct([
    for k, v in var.subnets : split("-", k)[0] # "private" or "public"
  ]))

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.prefix}-${each.key}-rtb"
  })
}

# ルートテーブルとサブネットのアソシエーション
resource "aws_route_table_association" "this" {
  for_each = var.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[split("-", each.key)[0]].id
}

# IGWへのデフォルトルート（publicルートテーブルのみ）
resource "aws_route" "igw" {
  count = var.create_igw ? 1 : 0

  route_table_id         = aws_route_table.this["public"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

# =============================================================
# デフォルトセキュリティグループ
# デフォルトSGのルールを全削除（セキュリティベストプラクティス）
# =============================================================
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # ingressもegressも定義しない = 全通信を暗黙拒否
  tags = merge(var.tags, {
    Name = "${var.prefix}-default-sg-DO-NOT-USE"
  })
}
