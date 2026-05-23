# NAT Gatewayを使わずにAWSサービスへプライベート通信するためのVPC Endpoint群
# Interface型はENIを作成するためセキュリティグループが必要

resource "aws_security_group" "vpce" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "VPC Endpoint用 - VPC内からのHTTPS通信のみ許可"
  vpc_id      = var.vpc_id

  ingress {
    description = "VPC内からのHTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# S3はGateway型（無料）
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
}

# DynamoDBはGateway型（無料）
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
}

# 以下はInterface型（ENI経由）
locals {
  interface_services = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "ssm",
    "sts",
    "bedrock-runtime",
    "states", # Step Functions
    "ecs",
    "ecs-agent",
    "ecs-telemetry",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_services)

  vpc_id             = var.vpc_id
  service_name       = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpce.id]
  # プライベートDNSを有効化することでSDKの向き先を自動的に変更
  private_dns_enabled = true
}
