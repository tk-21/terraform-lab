# =============================================================
# VPC モジュール
# Cell構成に合わせてAZ-a・AZ-c の2AZで構成する
# パブリック: ALB配置用 / プライベート: EKSノード配置用
# NAT GW は1台のみ（コスト最適化。本番では各AZに1台推奨）
# =============================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# --- VPC ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-vpc"
    # EKSがVPCを認識するための必須タグ
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# --- インターネットゲートウェイ ---
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.common_tags, { Name = "${var.project_name}-igw" })
}

# --- パブリックサブネット（ALB用）---
resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-${each.key}"
    # ALB自動検出に必要なタグ
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# --- プライベートサブネット（EKSノード用）---
resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-private-${each.key}"
    # 内部ELB自動検出に必要なタグ
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Karpenterがサブネットを検出するためのタグ
    "karpenter.sh/discovery" = var.cluster_name
    # EC2NodeClassがAZ単位でサブネットを絞り込むためのタグ
    "availability-zone" = each.value.az
  })
}

# --- Elastic IP（NAT GW用）---
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.common_tags, { Name = "${var.project_name}-nat-eip" })
}

# --- NAT ゲートウェイ（AZ-a に1台）---
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["az-a"].id

  tags       = merge(var.common_tags, { Name = "${var.project_name}-nat" })
  depends_on = [aws_internet_gateway.main]
}

# --- ルートテーブル: パブリック ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-rt-public" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# --- ルートテーブル: プライベート ---
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-rt-private" })
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
