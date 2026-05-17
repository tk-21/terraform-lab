locals {
  common_tags = merge(var.tags, {
    Project     = "aws-multilayer-firewall-terraform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  })
}

# -------------------------------------------------------------------
# VPC
# -------------------------------------------------------------------
resource "aws_vpc" "main" {
  # 設計理由: /16 で十分なアドレス空間を確保し、将来のサブネット追加に対応する
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-vpc"
  })
}

# -------------------------------------------------------------------
# Subnets
# -------------------------------------------------------------------
resource "aws_subnet" "public" {
  # 設計理由: for_each で AZ ごとのサブネットを宣言的に管理し、
  # 将来の AZ 追加も変数変更のみで対応できるようにする
  for_each = {
    "1a" = "10.0.0.0/24"
    "1c" = "10.0.1.0/24"
  }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = "ap-northeast-${each.key}"
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = {
    "1a" = "10.0.10.0/24"
    "1c" = "10.0.11.0/24"
  }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = "ap-northeast-${each.key}"

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-private-${each.key}"
    Tier = "private"
  })
}

resource "aws_subnet" "firewall" {
  # 設計理由: /28 で最小限のアドレスを割り当て。
  # Network Firewall エンドポイントは AZ ごとに 1 つ必要なため 2 AZ 分用意する。
  # Phase 2 で使用するが、今フェーズでサブネットを作成しておくことで
  # ルートテーブルの設計変更を Phase 2 に集約できる。
  for_each = {
    "1a" = "10.0.100.0/28"
    "1c" = "10.0.101.0/28"
  }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = "ap-northeast-${each.key}"

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-firewall-${each.key}"
    Tier = "firewall"
  })
}

# -------------------------------------------------------------------
# Internet Gateway
# -------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  # 設計理由: Public サブネットからインターネットへの出口。
  # Private サブネットは Phase 1 では NAT Gateway を設けず、
  # SSM エンドポイント経由で Session Manager を利用する。
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-igw"
  })
}

# -------------------------------------------------------------------
# Route Tables
# -------------------------------------------------------------------
resource "aws_route_table" "public" {
  # 設計理由: Public サブネット用ルートテーブル。
  # Phase 1 では IGW への直接ルートを持っていたが、Phase 2 で Network Firewall を
  # 挿入するため、0.0.0.0/0 のルートは network_firewall モジュール側で管理する。
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-rtb-public"
  })
}

resource "aws_route_table" "private" {
  # 設計理由: Private サブネット用ルートテーブル。
  # Phase 1 では NAT Gateway なし（コスト考慮）。
  # EC2 の外部通信は VPC エンドポイント（SSM）経由のみを想定する。
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-rtb-private"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# Firewall サブネットの RT association は Phase 2 の network_firewall モジュールで管理する

# -------------------------------------------------------------------
# VPC Endpoints for SSM (Private サブネットから NAT Gateway なしで SSM を使うため)
# -------------------------------------------------------------------
resource "aws_vpc_endpoint" "ssm" {
  # 設計理由: Private サブネットに NAT Gateway を置かずに SSM Agent を動作させるため、
  # PrivateLink エンドポイントが必要。com.amazonaws.ap-northeast-1.ssm の他に
  # ec2messages と ssmmessages も必須（セッション確立に使用）。
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private["1a"].id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-vpce-ssm"
  })
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private["1a"].id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-vpce-ec2messages"
  })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private["1a"].id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-vpce-ssmmessages"
  })
}

resource "aws_security_group" "vpc_endpoint" {
  # 設計理由: VPC エンドポイントへの通信は VPC 内部（10.0.0.0/16）の 443 のみ許可。
  # 外部からの直接アクセスは不要。
  name        = "${var.prefix}-sg-vpce"
  description = "VPC Endpoint用 - VPC内部からの443のみ許可"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "VPC内部からのHTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-sg-vpce"
  })
}

# -------------------------------------------------------------------
# VPC Flow Logs
# -------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_log" {
  # 設計理由: セキュリティ検証用にトラフィックを記録する。
  # 保持期間 7 日はコスト最小化のため。本番では 90 日以上を推奨。
  name              = "/aws/vpc/flow-log/${var.prefix}-vpc"
  retention_in_days = 7

  tags = local.common_tags
}

resource "aws_iam_role" "flow_log" {
  # 設計理由: VPC Flow Logs が CloudWatch Logs に書き込むための最小権限ロール。
  name = "${var.prefix}-role-vpc-flow-log"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_log" {
  name = "${var.prefix}-policy-vpc-flow-log"
  role = aws_iam_role.flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.flow_log.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  # 設計理由: ALL を記録することで許可・拒否両方のパターンを Phase 4 の検証で確認できる。
  # ACCEPT のみでは NACL/SG によるブロックが見えない。
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = aws_cloudwatch_log_group.flow_log.arn

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-flow-log"
  })
}
