resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  # VPC Endpointのプライベートホスト名解決に必要
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# EKSノード・Podが配置されるプライベートサブネット
# NAT Gatewayがないため、インターネットへの直接アウトバウンドは不可
# AWSサービスへのアクセスはVPC Endpoint経由のみ
resource "aws_subnet" "private" {
  for_each = { for idx, cidr in var.private_subnet_cidrs : idx => cidr }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = var.azs[each.key]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-${var.azs[each.key]}"
    # Karpenterがノードを配置するサブネットを識別するためのタグ
    "karpenter.sh/discovery" = "${local.name_prefix}-eks"
    # EKS内部ELB用タグ (ALBではなくKubernetes internal serviceに使用)
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# パブリックサブネット: ALB配置専用。NAT Gatewayは置かない
resource "aws_subnet" "public" {
  for_each = { for idx, cidr in var.public_subnet_cidrs : idx => cidr }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = var.azs[each.key]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name                     = "${local.name_prefix}-public-${var.azs[each.key]}"
    "kubernetes.io/role/elb" = "1"
  })
}

# Internet Gateway: パブリックサブネットのALBがHTTPSを受け付けるために必要
# EKSノードはプライベートサブネットにいるためIGWを直接使用しない
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# パブリックサブネット用ルートテーブル (IGW経由でインターネットへ)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rtb-public"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# プライベートサブネット用ルートテーブル (デフォルトゲートウェイなし)
# NAT Gatewayがないため、インターネット向けルートは追加しない
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rtb-private"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# VPC Endpoint用セキュリティグループ
# EKSノードからのHTTPS(443)のみ許可する最小権限設計
resource "aws_security_group" "vpc_endpoint" {
  name        = "${local.name_prefix}-sg-vpce"
  description = "VPC Endpoint用。EKSノードからのHTTPSのみ許可する"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-sg-vpce"
  })
}

# Interface型VPC Endpoint (ECR/STS/CloudWatch/SSM/Bedrock)
# NAT Gatewayの代替として、AWSマネージドサービスへのアクセスをVPC内に閉じる
resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  # プライベートDNSを有効にすることでSDK/CLIの設定変更なしにVPC経由でアクセスできる
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpce-${each.key}"
  })
}

# Gateway型VPC Endpoint (S3)
# Interface型と異なりルートテーブルに追加する方式でコストゼロ
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpce-s3"
  })
}
