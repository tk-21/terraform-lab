data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  common_tags = {
    ManagedBy = "terraform"
    Project   = "pr-driven-iac-lab"
    Component = "atlantis-infra"
  }
}

# ──────────────────────────────────────────
# VPC
# ──────────────────────────────────────────

resource "aws_vpc" "atlantis" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  # VPC Endpointのプライベートホスト名解決に必須
  enable_dns_support = true

  tags = merge(local.common_tags, { Name = "atlantis-vpc" })
}

# ──────────────────────────────────────────
# パブリックサブネット (ALB配置用)
# ──────────────────────────────────────────

resource "aws_subnet" "public" {
  for_each = {
    "a" = { cidr = "10.0.1.0/24", az = data.aws_availability_zones.available.names[0] }
    "c" = { cidr = "10.0.2.0/24", az = data.aws_availability_zones.available.names[1] }
  }

  vpc_id                  = aws_vpc.atlantis.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, { Name = "atlantis-public-${each.key}" })
}

# ──────────────────────────────────────────
# プライベートサブネット (ECSタスク配置用)
# ──────────────────────────────────────────

resource "aws_subnet" "private" {
  for_each = {
    "a" = { cidr = "10.0.10.0/24", az = data.aws_availability_zones.available.names[0] }
    "c" = { cidr = "10.0.11.0/24", az = data.aws_availability_zones.available.names[1] }
  }

  vpc_id            = aws_vpc.atlantis.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(local.common_tags, { Name = "atlantis-private-${each.key}" })
}

# ──────────────────────────────────────────
# Internet Gateway (ALBのインターネット疎通用)
# NAT GatewayはVPC Endpointで代替するため作成しない
# ──────────────────────────────────────────

resource "aws_internet_gateway" "atlantis" {
  vpc_id = aws_vpc.atlantis.id

  tags = merge(local.common_tags, { Name = "atlantis-igw" })
}

# ──────────────────────────────────────────
# ルートテーブル
# ──────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.atlantis.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.atlantis.id
  }

  tags = merge(local.common_tags, { Name = "atlantis-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# プライベートサブネット用ルートテーブル (デフォルトルートなし)
# VPC Endpoint経由でAWSサービスにアクセスするため、インターネットへのルートは不要
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.atlantis.id

  tags = merge(local.common_tags, { Name = "atlantis-private-rt" })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ──────────────────────────────────────────
# VPC Endpoints
# NAT Gateway ($45/月) を使わずプライベートサブネットからAWSサービスにアクセスする
# ──────────────────────────────────────────

# S3 Gateway Endpoint (無料)
# ECSタスクがTerraformステートをS3から読み書きするために必要
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.atlantis.id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, { Name = "atlantis-vpce-s3" })
}

# DynamoDB Gateway Endpoint (無料)
# Terraformステートロック (DynamoDB) へのアクセスに必要
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.atlantis.id
  service_name      = "com.amazonaws.ap-northeast-1.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, { Name = "atlantis-vpce-dynamodb" })
}

# Interface Endpoint用セキュリティグループ
# VPC内からのHTTPS通信のみ許可
resource "aws_security_group" "vpce" {
  name        = "atlantis-vpce-sg"
  description = "VPC Interface Endpointへのアクセスを許可"
  vpc_id      = aws_vpc.atlantis.id

  ingress {
    description = "VPC内からのHTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.atlantis.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "atlantis-vpce-sg" })
}

# ECR API Interface Endpoint
# ECSがECRからコンテナイメージのメタデータを取得するために必要
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.atlantis.id
  service_name        = "com.amazonaws.ap-northeast-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "atlantis-vpce-ecr-api" })
}

# ECR DKR Interface Endpoint
# ECSがECRからDockerイメージレイヤーをPullするために必要
# ghcr.io はパブリックエンドポイントのためALB経由でインターネットアクセスが必要だが、
# ECRにミラーする場合はこのエンドポイントを活用できる
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.atlantis.id
  service_name        = "com.amazonaws.ap-northeast-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "atlantis-vpce-ecr-dkr" })
}

# CloudWatch Logs Interface Endpoint
# ECSタスクのログをCloudWatch Logsに送信するために必要
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.atlantis.id
  service_name        = "com.amazonaws.ap-northeast-1.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "atlantis-vpce-logs" })
}

# SSM Interface Endpoint
# ECSタスクがSSM Parameter Storeからシークレット(GitHubトークン等)を取得するために必要
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.atlantis.id
  service_name        = "com.amazonaws.ap-northeast-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "atlantis-vpce-ssm" })
}
