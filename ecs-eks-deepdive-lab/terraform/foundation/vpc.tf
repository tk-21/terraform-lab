resource "aws_vpc" "main" {
  cidr_block         = "10.0.0.0/16"
  enable_dns_support = true
  # EKSの必須要件: ノードがhostnameで互いに解決できるようにする
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

# --- Public Subnets (ALB配置用) ---
resource "aws_subnet" "public" {
  for_each = {
    "1a" = { cidr = "10.0.0.0/24", az = "ap-northeast-1a" }
    "1c" = { cidr = "10.0.1.0/24", az = "ap-northeast-1c" }
  }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-public-${each.key}"
    # AWS LBCがPublic ALBを配置するサブネットを判別するために参照するタグ
    "kubernetes.io/role/elb" = "1"
  }
}

# --- Private Subnets (ECS Tasks / EKS Nodes配置用) ---
resource "aws_subnet" "private" {
  for_each = {
    "1a" = { cidr = "10.0.128.0/24", az = "ap-northeast-1a" }
    "1c" = { cidr = "10.0.129.0/24", az = "ap-northeast-1c" }
  }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name = "${var.project}-private-${each.key}"
    # AWS LBCがInternal ALBを配置するサブネットを判別するために参照するタグ
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# --- Internet Gateway (Public Subnet専用) ---
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# --- NAT Gateway (1台のみ: ap-northeast-1a) ---
# EKSアドオン(Karpenter/KEDA)のコンテナイメージがECR Publicからpullされるため必要
# 本番ではECR pull-through cacheで置き換え、NAT GWを廃止する
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["1a"].id
  tags          = { Name = "${var.project}-nat-gw" }

  depends_on = [aws_internet_gateway.main]
}

# --- Route Tables ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rtb" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-private-rtb" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# --- Outputs ---
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "public_subnet_id_1a" {
  value = aws_subnet.public["1a"].id
}

output "private_subnet_id_1a" {
  value = aws_subnet.private["1a"].id
}

output "private_subnet_id_1c" {
  value = aws_subnet.private["1c"].id
}

output "private_route_table_id" {
  description = "プライベートルートテーブルID (Gateway Endpointのルート追加用)"
  value       = aws_route_table.private.id
}
