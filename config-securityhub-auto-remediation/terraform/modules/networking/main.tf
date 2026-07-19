locals {
  prefix = "csar"
}

# ─────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block         = var.vpc_cidr
  enable_dns_support = true
  # VPC Endpoint (Interface型) の名前解決に必要
  enable_dns_hostnames = true

  tags = {
    Name = "${local.prefix}-vpc-${var.environment}"
  }
}

# ─────────────────────────────────────────────
# プライベートサブネット (Lambda用、NAT Gateway なし)
# ─────────────────────────────────────────────

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${local.prefix}-subnet-private-${var.availability_zones[count.index]}-${var.environment}"
    Tier = "private"
  }
}

# ─────────────────────────────────────────────
# ルートテーブル (プライベートサブネット用)
# ─────────────────────────────────────────────

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.prefix}-rtb-private-${var.environment}"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ─────────────────────────────────────────────
# Lambda用セキュリティグループ
# Interface型VPC Endpointへの443アウトバウンドのみ許可
# ─────────────────────────────────────────────

resource "aws_security_group" "lambda" {
  name        = "${local.prefix}-sg-lambda-${var.environment}"
  description = "Lambda修復関数用SG: VPC Endpoint経由のAWS APIアクセスのみ許可"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "VPC Endpoint (Interface型) へのHTTPS通信"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${local.prefix}-sg-lambda-${var.environment}"
  }
}

# Interface型VPC Endpoint用セキュリティグループ
resource "aws_security_group" "vpc_endpoint" {
  name        = "${local.prefix}-sg-vpce-${var.environment}"
  description = "VPC Endpoint用SG: Lambda SGからの443インバウンドのみ許可"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Lambda SGからのHTTPS通信"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = {
    Name = "${local.prefix}-sg-vpce-${var.environment}"
  }
}

# ─────────────────────────────────────────────
# Gateway型VPC Endpoints (S3 / DynamoDB)
# ルートテーブルへの自動経路追加でコストゼロ
# ─────────────────────────────────────────────

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${local.prefix}-vpce-s3-${var.environment}"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${local.prefix}-vpce-dynamodb-${var.environment}"
  }
}

# ─────────────────────────────────────────────
# Interface型VPC Endpoints
# Lambda→AWS API通信をVPC内で完結させる (NAT Gateway不要)
# ─────────────────────────────────────────────

locals {
  interface_endpoints = {
    ssm         = "com.amazonaws.ap-northeast-1.ssm"
    lambda      = "com.amazonaws.ap-northeast-1.lambda"
    logs        = "com.amazonaws.ap-northeast-1.logs"
    config      = "com.amazonaws.ap-northeast-1.config"
    securityhub = "com.amazonaws.ap-northeast-1.securityhub"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id             = aws_vpc.main.id
  service_name       = each.value
  vpc_endpoint_type  = "Interface"
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoint.id]
  # プライベートDNSを有効化: aws-sdk がエンドポイントURLを意識せずにアクセス可能になる
  private_dns_enabled = true

  tags = {
    Name = "${local.prefix}-vpce-${each.key}-${var.environment}"
  }
}
