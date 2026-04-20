# =============================================================================
# VPCモジュール - EKS Chaos Postmortem Generator
# 3層VPC構成: パブリック/プライベートサブネット × 2AZ
# =============================================================================

# VPC本体
# DNS解決とDNSホスト名を有効化（EKSで必須）
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true  # EKSノードがホスト名を持つために必要
  enable_dns_support   = true  # Route53リゾルバーを有効化

  tags = merge(var.tags, {
    Name        = "${var.project}-vpc-${var.environment}"
    Environment = var.environment
  })
}

# ============================================================
# パブリックサブネット（ALB/NAT GWを配置）
# ============================================================

# パブリックサブネット: ap-northeast-1a
resource "aws_subnet" "public_1a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true  # パブリックIPを自動付与

  tags = merge(var.tags, {
    Name                                        = "${var.project}-public-1a-${var.environment}"
    Environment                                 = var.environment
    # EKS ALBコントローラーがALB用サブネットを識別するためのタグ
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# パブリックサブネット: ap-northeast-1c
resource "aws_subnet" "public_1c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                        = "${var.project}-public-1c-${var.environment}"
    Environment                                 = var.environment
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ============================================================
# プライベートサブネット（EKSノードを配置）
# ============================================================

# プライベートサブネット: ap-northeast-1a
resource "aws_subnet" "private_1a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "ap-northeast-1a"

  tags = merge(var.tags, {
    Name                                        = "${var.project}-private-1a-${var.environment}"
    Environment                                 = var.environment
    # EKS Internal ALB（ClusterIP）用サブネットを識別するためのタグ
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# プライベートサブネット: ap-northeast-1c
resource "aws_subnet" "private_1c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "ap-northeast-1c"

  tags = merge(var.tags, {
    Name                                        = "${var.project}-private-1c-${var.environment}"
    Environment                                 = var.environment
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ============================================================
# インターネットゲートウェイ（パブリックサブネットのアウトバウンド用）
# ============================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name        = "${var.project}-igw-${var.environment}"
    Environment = var.environment
  })
}

# ============================================================
# NAT Gateway（プライベートサブネットのアウトバウンド用）
# コスト削減のため1AZにのみ配置（高可用性が必要な場合は各AZに配置）
# ============================================================

# NAT Gateway用のElastic IP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name        = "${var.project}-nat-eip-${var.environment}"
    Environment = var.environment
  })

  # IGWが作成された後にEIPを作成する
  depends_on = [aws_internet_gateway.main]
}

# NAT Gateway: 1aのパブリックサブネットにのみ配置（コスト最適化）
# 本番環境では可用性のため各AZに配置することを検討
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1a.id  # パブリックサブネットに配置

  tags = merge(var.tags, {
    Name        = "${var.project}-nat-${var.environment}"
    Environment = var.environment
  })

  depends_on = [aws_internet_gateway.main]
}

# ============================================================
# ルートテーブル設定
# ============================================================

# パブリックルートテーブル: IGW経由でインターネットへ
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name        = "${var.project}-rtb-public-${var.environment}"
    Environment = var.environment
  })
}

# プライベートルートテーブル: NAT GW経由でインターネットへ
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, {
    Name        = "${var.project}-rtb-private-${var.environment}"
    Environment = var.environment
  })
}

# ルートテーブルの関連付け
resource "aws_route_table_association" "public_1a" {
  subnet_id      = aws_subnet.public_1a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_1c" {
  subnet_id      = aws_subnet.public_1c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_1a" {
  subnet_id      = aws_subnet.private_1a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_1c" {
  subnet_id      = aws_subnet.private_1c.id
  route_table_id = aws_route_table.private.id
}
