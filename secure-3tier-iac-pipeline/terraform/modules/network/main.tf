locals {
  common_tags = {
    Project     = "secure-3tier-iac-pipeline"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }

  prefix = "s3t-${var.environment}"
}

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpc"
  })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-igw"
  })
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false # [セキュリティ] 自動パブリックIP割当は無効。ALBのみパブリック配置

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-public-subnet-${count.index + 1}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = length(var.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-private-subnet-${count.index + 1}"
    Tier = "private"
  })
}

resource "aws_subnet" "data" {
  count = length(var.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.data_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-data-subnet-${count.index + 1}"
    Tier = "data"
  })
}

# ── Elastic IP + NAT Gateway (各AZに1台) ─────────────────────────────────────

resource "aws_eip" "nat" {
  count = length(var.azs)

  domain = "vpc"

  # [コスト] NAT GatewayはAZごとに1台で高可用性を確保。
  # 月額約$130/台 × 3AZ = 約$390/月の固定費が発生する。
  # 開発環境ではAZ数を1に減らすことでコスト削減可能。
  tags = merge(local.common_tags, {
    Name = "${local.prefix}-nat-eip-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = length(var.azs)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-nat-${count.index + 1}"
    AZ   = var.azs[count.index]
  })

  depends_on = [aws_internet_gateway.main]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-public-rtb"
  })
}

resource "aws_route_table_association" "public" {
  count = length(var.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count = length(var.azs)

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-private-rtb-${count.index + 1}"
    AZ   = var.azs[count.index]
  })
}

resource "aws_route_table_association" "private" {
  count = length(var.azs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# [設計意図] データ層はインターネットへのルートを持たない。
# RDSはAWS内部エンドポイントのみ使用するため、NAT経由通信は不要。
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-data-rtb"
  })
}

resource "aws_route_table_association" "data" {
  count = length(var.azs)

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# ── NACL: Public Subnet ───────────────────────────────────────────────────────

# [設計意図] SG との2段階防御。NACLはステートレスなのでエフェメラルポートの明示が必要。

resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id

  # インバウンド: HTTP
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  # インバウンド: HTTPS
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # インバウンド: エフェメラルポート (NACLはステートレスのため必須)
  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # アウトバウンド: すべて許可
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-public-nacl"
  })
}

# ── NACL: Private Subnet ─────────────────────────────────────────────────────

resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  # インバウンド: VPC内部トラフィックのみ許可
  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  # アウトバウンド: HTTPS (EC2→Secrets Manager/SSM等のAWS APIはNAT経由のHTTPS)
  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # アウトバウンド: エフェメラルポート (NATからの戻りパケット)
  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-private-nacl"
  })
}

# ── NACL: Data Subnet ────────────────────────────────────────────────────────

# [セキュリティ] データ層は最大限に閉じる。管理トラフィックも通さない。
# MySQL (3306) を Private Subnet からのみ許可。

resource "aws_network_acl" "data" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.data[*].id

  # インバウンド: Private Subnetからのみ MySQL を許可
  dynamic "ingress" {
    for_each = var.private_subnet_cidrs
    content {
      rule_no    = 100 + ingress.key * 10
      protocol   = "tcp"
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 3306
      to_port    = 3306
    }
  }

  # アウトバウンド: Private Subnetへのエフェメラルポート (RDS→クライアントの戻り)
  dynamic "egress" {
    for_each = var.private_subnet_cidrs
    content {
      rule_no    = 100 + egress.key * 10
      protocol   = "tcp"
      action     = "allow"
      cidr_block = egress.value
      from_port  = 1024
      to_port    = 65535
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-data-nacl"
  })
}

# ── VPC Flow Logs ─────────────────────────────────────────────────────────────

# [セキュリティ] セキュリティインシデント調査・不正アクセス検知のため
# ACCEPT/REJECT 両方のトラフィックを記録する。

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flowlogs/${local.prefix}"
  retention_in_days = var.flow_logs_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpc-flowlogs"
  })
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "${local.prefix}-vpc-flowlogs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpc-flowlogs-role"
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${local.prefix}-vpc-flowlogs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  # [セキュリティ] 最小権限: logs:CreateLogGroup と logs:CreateLogDelivery は付与しない。
  # ロググループは Terraform が事前作成するため CreateLogGroup は不要。
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL" # ACCEPT/REJECT 両方記録
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpc-flowlog"
  })
}

# ── Phase 2 への橋渡しメモ ────────────────────────────────────────────────────
# [注意] Phase 2 で EC2 Launch Template を実装する際は必ず以下を設定すること:
#   metadata_options {
#     http_tokens                 = "required"      # IMDSv2 強制
#     http_put_response_hop_limit = 1               # コンテナからのアクセス防止
#     http_endpoint               = "enabled"
#   }
