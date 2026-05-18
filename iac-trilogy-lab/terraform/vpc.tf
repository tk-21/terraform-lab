# -----------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block = local.vpc_cidr

  # DNS解決を有効化: SSM Session Manager のエンドポイント名前解決に必要
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.prefix}-vpc"
  }
}

# -----------------------------------------------------------------------
# パブリックサブネット
# -----------------------------------------------------------------------
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.subnet_cidr
  availability_zone = local.subnet_az

  # EC2 起動時にパブリックIPを自動付与
  # NAT Gateway 不使用のため、パブリックIPで直接インターネット疎通を確保する
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.prefix}-public-1a"
  }
}

# -----------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  # IGW を先に作成しないとルートテーブルのデプロイが失敗するため明示的に依存を宣言
  tags = {
    Name = "${local.prefix}-igw"
  }
}

# -----------------------------------------------------------------------
# パブリックルートテーブル
# -----------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  # デフォルトルート: 全トラフィックをIGW経由でインターネットへ
  # NAT Gateway を使わないコスト最適設計（NAT GW は約$32/月のコスト増）
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
