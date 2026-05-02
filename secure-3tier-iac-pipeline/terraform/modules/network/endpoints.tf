data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# VPC エンドポイント専用 Security Group
# [設計意図] Interface 型エンドポイントへのアクセスを VPC 内 HTTPS (443) に限定
# ---------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.prefix}-vpc-endpoints-sg"
  description = "Security group for VPC Interface Endpoints — HTTPS from within VPC only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpc-endpoints-sg"
  })
}

# ---------------------------------------------------------------------------
# Gateway 型エンドポイント (料金なし)
# [コスト] Gateway 型は無料。S3/DynamoDB へのトラフィックが NAT Gateway を経由しなくなる
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.data.id]
  )

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpce-s3"
  })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.data.id]
  )

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpce-dynamodb"
  })
}

# ---------------------------------------------------------------------------
# Interface 型エンドポイント
# [コスト] Interface 型は ~$7.5/月/エンドポイント。
#          NAT Gateway (~$45/月 + データ転送料) より SSM/SM/KMS 用途なら安価
# [セキュリティ] プライベートサブネットから SSH (22番ポート) なしで AWS API にアクセス可能
# ---------------------------------------------------------------------------
locals {
  interface_endpoints = {
    ssm            = "com.amazonaws.${data.aws_region.current.name}.ssm"
    ssmmessages    = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
    ec2messages    = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
    secretsmanager = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
    logs           = "com.amazonaws.${data.aws_region.current.name}.logs"
    kms            = "com.amazonaws.${data.aws_region.current.name}.kms"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  # [設計意図] private_dns_enabled=true によりエンドポイント URL の変更不要
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpce-${each.key}"
  })
}
