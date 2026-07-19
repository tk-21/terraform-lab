locals {
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
  })

  # AZをインデックスで引き当てるためのリスト（ap-northeast-1a/b/c）
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # サブネットCIDR → AZ のマッピングを生成する
  # index()でCIDRの順序からAZを決定する
  private_subnet_map = {
    for i, cidr in var.private_subnet_cidrs : cidr => local.azs[i % var.az_count]
  }

  tgw_subnet_map = {
    for i, cidr in var.tgw_subnet_cidrs : cidr => local.azs[i % var.az_count]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-vpc"
  })
}

# プライベートサブネット: EC2インスタンスやエンドポイントを配置する
resource "aws_subnet" "private" {
  for_each = local.private_subnet_map

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.key
  availability_zone = each.value

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-private-${each.value}"
    Type = "private"
  })
}

# TGW専用サブネット: Transit GatewayのENIを配置するためにプライベートサブネットと分離する
# 分離する理由: TGW経由のトラフィックルートとVPC内部トラフィックのルートを独立して制御するため。
# 同一ルートテーブルにすると、TGWへの静的ルートがVPC内通信に影響する可能性がある。
resource "aws_subnet" "tgw" {
  for_each = local.tgw_subnet_map

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.key
  availability_zone = each.value

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-tgw-${each.value}"
    Type = "tgw"
  })
}

# プライベートサブネット用ルートテーブル
# TGW経由のルートはPhase2でここに追加する
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-rtb-private"
  })
}

# TGW専用サブネット用ルートテーブル
# TGWアタッチメントのENIが使用するルートテーブル。プライベート用と分離することで、
# TGWサイドのルーティングを独立して管理できる。
resource "aws_route_table" "tgw" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-rtb-tgw"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "tgw" {
  for_each = aws_subnet.tgw

  subnet_id      = each.value.id
  route_table_id = aws_route_table.tgw.id
}

# SSM接続用VPCエンドポイント（NATGWなしでSystems Managerを使うために必須）
# プライベートサブネットに配置する: インスタンスが存在するサブネットからアクセスするため
resource "aws_security_group" "vpc_endpoint" {
  name        = "${var.vpc_name}-vpce-sg"
  description = "VPCエンドポイント用セキュリティグループ"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "VPC内からのHTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-vpce-sg"
  })
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.ap-northeast-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-vpce-ssm"
  })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.ap-northeast-1.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-vpce-ssmmessages"
  })
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.ap-northeast-1.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-vpce-ec2messages"
  })
}
