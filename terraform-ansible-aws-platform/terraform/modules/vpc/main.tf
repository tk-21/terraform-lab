# 3-tier構成のベースVPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}

# パブリックサブネット用インターネットゲートウェイ
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}

# パブリックサブネット（Bastion / ALB配置用）
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = ["10.0.0.0/24", "10.0.1.0/24"][count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-${var.environment}-public-${var.azs[count.index]}"
  }
}

# プライベートサブネット（App EC2配置用）
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = ["10.0.10.0/24", "10.0.11.0/24"][count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-${var.azs[count.index]}"
  }
}

# DBサブネット（将来のRDS配置用、今回はEC2未配置）
resource "aws_subnet" "db" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = ["10.0.20.0/24", "10.0.21.0/24"][count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-db-${var.azs[count.index]}"
  }
}

# NATゲートウェイ用Elastic IP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-${var.environment}-nat-eip"
  }
}

# Privateサブネット用NATゲートウェイ（コスト最適化のため1AZのみ作成）
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project}-${var.environment}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# パブリックサブネット用ルートテーブル（IGW経由でインターネットへ）
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-public-rt"
  }
}

# プライベートサブネット用ルートテーブル（NAT GW経由でインターネットへ）
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-private-rt"
  }
}

# DBサブネット用ルートテーブル（インターネット接続なし）
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-db-rt"
  }
}

# サブネットとルートテーブルの関連付け
resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  count = 2

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}
