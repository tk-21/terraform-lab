data "aws_availability_zones" "available" {
  state = "available"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # なぜ: VPC Endpoint の DNS 解決に必須
  enable_dns_support   = true

  tags = merge(var.common_tags, { Name = "${var.project}-vpc" })
}

# プライベートサブネット (2AZ)
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # なぜ: Lambda/ECS はプライベートサブネットに配置し、
  #       パブリック IP を持たせない設計
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${var.project}-private-${count.index + 1}"
  })
}

# ルートテーブル (プライベート用)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  # なぜ: NAT Gateway を使わないため、デフォルトルートなし
  #       インターネット通信は VPC Endpoint 経由のみ許可
  tags = merge(var.common_tags, { Name = "${var.project}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# セキュリティグループ: VPC Endpoint 用
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project}-vpc-endpoints-sg"
  description = "VPC Endpoint へのアクセスを許可"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # なぜ: VPC 内部からのみ HTTPS アクセスを許可
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, { Name = "${var.project}-vpc-endpoints-sg" })
}

# VPC Endpoint: SQS (Interface)
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true # なぜ: 既存コードの endpoint URL を変更せずに利用可能

  tags = merge(var.common_tags, { Name = "${var.project}-sqs-endpoint" })
}

# VPC Endpoint: DynamoDB (Gateway) ← 無料
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.common_tags, { Name = "${var.project}-dynamodb-endpoint" })
}

# VPC Endpoint: ECR API (Interface) ← ECS Fargate が ECR から pull するために必要
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-ecr-api-endpoint" })
}

# VPC Endpoint: ECR DKR (Interface) ← Docker イメージ layer の pull に必要
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-ecr-dkr-endpoint" })
}

# VPC Endpoint: CloudWatch Logs (Interface) ← ECS/Lambda のログ送信
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-logs-endpoint" })
}

# VPC Endpoint: SSM (Interface) ← Parameter Store 参照
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-ssm-endpoint" })
}

# VPC Endpoint: Step Functions (Interface)
resource "aws_vpc_endpoint" "states" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.states"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-states-endpoint" })
}

# VPC Endpoint: X-Ray (Interface) ← トレーシング
resource "aws_vpc_endpoint" "xray" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.xray"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-xray-endpoint" })
}

# S3 Gateway Endpoint ← ECR の layer データは S3 から取得される
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.common_tags, { Name = "${var.project}-s3-endpoint" })
}
