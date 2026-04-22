# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# パブリックサブネット
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.name_prefix}-public-${var.availability_zones[count.index]}"
  }
}

# プライベートサブネット
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}"
  }
}

# EIP for NAT Gateway（シングルNAT、コスト最適化）
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }
}

# NAT Gateway（パブリックサブネットに配置）
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# パブリックルートテーブル
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

# プライベートルートテーブル（NAT Gateway向け）
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-private-rt"
  }
}

# パブリックサブネットとルートテーブルの関連付け
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# プライベートサブネットとルートテーブルの関連付け
resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# MSK用セキュリティグループ
resource "aws_security_group" "msk" {
  name        = "${var.name_prefix}-msk-sg"
  description = "MSK Serverless用セキュリティグループ"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MSK IAM認証ポート from Lambda"
    from_port       = 9098
    to_port         = 9098
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  ingress {
    description     = "MSK IAM認証ポート from Flink"
    from_port       = 9098
    to_port         = 9098
    protocol        = "tcp"
    security_groups = [aws_security_group.flink.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-msk-sg"
  }
}

# Lambda Producer用セキュリティグループ
# Lambda ProducerはMSKへの書き込みとCloudWatchへのログ送信が必要
resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Lambda Producer用セキュリティグループ"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "MSK IAM認証ポートへの接続"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS（CloudWatch Logsへのログ送信）"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-lambda-sg"
  }
}

# Flink用セキュリティグループ
# FlinkはMSKからの読み込みとS3への書き込みが必要
resource "aws_security_group" "flink" {
  name        = "${var.name_prefix}-flink-sg"
  description = "Managed Flink用セキュリティグループ"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Flink UI（VPC内からのアクセスのみ許可）"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "MSK IAM認証ポートへの接続"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS（S3書き込み・CloudWatch Logs）"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-flink-sg"
  }
}

# VPC Latticeエンドポイント用セキュリティグループ
resource "aws_security_group" "vpc_lattice" {
  name        = "${var.name_prefix}-vpc-lattice-sg"
  description = "VPC Latticeエンドポイント用セキュリティグループ"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS（VPC内からのVPC Latticeアクセス）"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description     = "MSK IAM認証ポートへの転送"
    from_port       = 9098
    to_port         = 9098
    protocol        = "tcp"
    security_groups = [aws_security_group.msk.id]
  }

  tags = {
    Name = "${var.name_prefix}-vpc-lattice-sg"
  }
}
