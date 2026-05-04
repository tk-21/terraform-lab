# =============================================================
# Step 1: VPC — ネットワーク基盤
#
# 【学習ポイント】
#   - VPC / サブネット / IGW / ルートテーブルの関係
#   - count メタ引数でリソースをループ生成する方法
#   - data ソースで AZ 情報を動的取得する方法
#   - locals で共通タグを一元管理する方法
# =============================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------------
# locals: 全リソースに付与する共通タグ
# 【ポイント】ハードコードせず locals で一元管理することで
#             タグの変更が1箇所で済む
# -------------------------------------------------------------
locals {
  common_tags = {
    Environment = "handson"
    ManagedBy   = "terraform"
    Project     = var.prefix
  }
}

# -------------------------------------------------------------
# data: 利用可能な AZ 一覧を動的取得
# 【ポイント】リージョンをハードコードしないことで
#             別リージョンへの移植が容易になる
# -------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

# -------------------------------------------------------------
# VPC
# 【ポイント】
#   enable_dns_hostnames = true にしないと EC2 に DNS 名が
#   付与されず、RDS エンドポイントの名前解決もできない
# -------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true   # VPC 内の DNS 解決を有効化
  enable_dns_hostnames = true   # EC2 インスタンスに DNS 名を付与

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-vpc"
  })
}

# -------------------------------------------------------------
# Internet Gateway
# 【ポイント】IGW は VPC に 1つだけアタッチできる
#             これがないとパブリックサブネットでも外部通信不可
# -------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-igw"
  })
}

# -------------------------------------------------------------
# パブリックサブネット (count でループ生成)
# 【ポイント】
#   - count.index で AZ とCIDR を対応付ける
#   - map_public_ip_on_launch = true で起動時に自動でパブリック IP を付与
# -------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true # パブリックIPを自動付与

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-public-subnet-${count.index + 1}"
    Tier = "Public"
  })
}

# -------------------------------------------------------------
# プライベートサブネット
# 【ポイント】
#   - map_public_ip_on_launch = false（デフォルト）
#   - インターネットから直接到達不可 → RDS などを配置する
# -------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-private-subnet-${count.index + 1}"
    Tier = "Private"
  })
}

# -------------------------------------------------------------
# パブリック用ルートテーブル
# 【ポイント】
#   0.0.0.0/0 → IGW のルートを追加することで
#   このルートテーブルに関連付けたサブネットがパブリックになる
# -------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-public-rtb"
  })
}

# パブリックサブネットにルートテーブルを関連付け
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -------------------------------------------------------------
# プライベート用ルートテーブル
# 【ポイント】
#   デフォルトルートを追加しないことで外部への通信をブロック
#   （NAT Gateway を使う場合はここにルートを追加する）
# -------------------------------------------------------------
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-private-rtb"
  })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
