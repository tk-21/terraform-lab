# =============================================================================
# VPCモジュール
# 設計思想: ネットワーク設計はImmutableなため Terraform で宣言的に管理する
# AZを動的に取得することで、リージョン変更時もコード修正不要にする
# =============================================================================

locals {
  # AZを動的取得: ap-northeast-1a/b/c をハードコードしない
  # 理由: リージョン間の移植性を確保するため
  az_count = min(length(data.aws_availability_zones.available.names), var.az_count)
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  # CIDR計算をlocalsに集約する
  # 理由: ビジネスロジック（サブネット設計）をmain.tfから分離して可読性を上げる
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true  # SSM Session Manager接続に必要
  enable_dns_support   = true  # DNS解決を有効化

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# パブリックサブネット（NAT GatewayとBastionを配置）
resource "aws_subnet" "public" {
  # count ではなく for_each を使う理由:
  # countはインデックスベースのため、中間要素を削除すると後続リソースが再作成される
  # for_eachはキーベースのため、特定AZのサブネットだけ削除しても他に影響しない
  for_each = { for i, az in local.azs : az => local.public_subnets[i] }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false  # パブリックIPは明示的にEIPで管理する

  tags = {
    Name = "${var.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

# プライベートサブネット（EC2本体を配置）
resource "aws_subnet" "private" {
  for_each = { for i, az in local.azs : az => local.private_subnets[i] }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name = "${var.name_prefix}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# NAT Gateway: プライベートサブネットからのアウトバウンド通信用
# ハンズオン用: AZ冗長化コスト削減のため1つだけ配置
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  # values()でマップから最初の1つを取得（ハンズオン用シングルNAT）
  subnet_id     = values(aws_subnet.public)[0].id
  allocation_id = aws_eip.nat.id
  tags          = { Name = "${var.name_prefix}-nat" }

  depends_on = [aws_internet_gateway.this]
  # depends_on を使っている理由:
  # IGWがアタッチされる前にNAT GatewayをEIPに紐付けるとエラーになるため
  # このケースは暗黙的依存関係では解決できないため明示的に記述
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# VPCエンドポイント（SSM Session Manager用）
# 理由: プライベートサブネットのEC2にSSMアクセスするためインターネット経由を避ける
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-${each.key}" }
}

resource "aws_security_group" "vpce" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "VPCエンドポイント用: EC2からSSMへのHTTPS通信を許可"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]  # VPC内からのみ許可
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
