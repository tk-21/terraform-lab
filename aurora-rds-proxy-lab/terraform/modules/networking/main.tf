# =============================================================
# VPC・サブネット・セキュリティグループ・VPC Endpoint 定義
# NAT Gateway は一切使用しない（コスト削減 + セキュリティ方針）
# Private Subnet からの AWS API アクセスは全て VPC Endpoint 経由
# =============================================================

locals {
  # 使用する AZ（ap-northeast-1a / 1c の2系統）
  azs = ["${var.aws_region}a", "${var.aws_region}c"]

  # サブネット CIDR 設計
  # Public Subnet:      ALB のみ（EC2/NAT Gateway は置かない）
  # Private App Subnet: ECS Fargate タスク配置用
  # Private DB Subnet:  Aurora / RDS Proxy 配置用（アプリ層と分離）
  public_cidrs      = ["10.0.0.0/24", "10.0.1.0/24"]
  private_app_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
  private_db_cidrs  = ["10.0.20.0/24", "10.0.21.0/24"]

  # Interface Endpoint 対象サービス一覧
  interface_endpoints = [
    "secretsmanager", # Secrets Manager（ローテーション Lambda 含む）
    "ecr.api",        # ECR API（イメージメタデータ）
    "ecr.dkr",        # ECR Docker Registry（イメージ pull）
    "logs",           # CloudWatch Logs
    "ssm",            # SSM Parameter Store
    "rds",            # RDS API（フェイルオーバー API 呼び出し用）
    "monitoring",     # CloudWatch メトリクス
  ]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # VPC Endpoint の名前解決に必須
  enable_dns_hostnames = true # RDS エンドポイントの DNS 解決に必須
}

# ─── Public Subnet（ALB 用）───────────────────────────────────
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # 不要なパブリック IP 割り当てを抑制（ALB は EIP 不使用）
  map_public_ip_on_launch = false
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ─── Private App Subnet（ECS Fargate）────────────────────────
resource "aws_subnet" "private_app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_app_cidrs[count.index]
  availability_zone = local.azs[count.index]
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id
  # デフォルトルートなし = インターネット到達不可
  # AWS API へは VPC Endpoint のみで接続（S3 は Gateway Endpoint）
}

resource "aws_route_table_association" "private_app" {
  count          = 2
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app.id
}

# ─── Private DB Subnet（Aurora / RDS Proxy）──────────────────
resource "aws_subnet" "private_db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_db_cidrs[count.index]
  availability_zone = local.azs[count.index]
}

resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id
  # DB 層は外部通信完全遮断（Aurora は VPC 内部通信のみ）
}

resource "aws_route_table_association" "private_db" {
  count          = 2
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db.id
}

# ─── VPC Endpoint 用セキュリティグループ ─────────────────────
resource "aws_security_group" "vpc_endpoint" {
  name        = "${var.prefix}-vpce-sg"
  description = "VPC Endpoint 専用 SG: VPC 内部からの HTTPS のみ許可"
  vpc_id      = aws_vpc.main.id

  # VPC Endpoint は 443 ポートで通信するため HTTPS のみ許可
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "VPC内部からのHTTPS（VPC Endpoint通信用）"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "全アウトバウンド許可"
  }
}

# ─── Interface Endpoints ──────────────────────────────────────
# Private DNS 有効化により、既存コードの変更なしに VPC Endpoint 経由になる
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true # エンドポイント DNS を自動的に向けてくれる

  # ECS タスクが配置される Private App Subnet に配置
  subnet_ids         = aws_subnet.private_app[*].id
  security_group_ids = [aws_security_group.vpc_endpoint.id]
}

# ─── S3 Gateway Endpoint ─────────────────────────────────────
# S3 は Gateway Endpoint（無料 + 高帯域）で接続
# ECR イメージ pull 時のレイヤーデータは S3 から取得するため必須
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # App / DB 両サブネットのルートテーブルに追加
  route_table_ids = [
    aws_route_table.private_app.id,
    aws_route_table.private_db.id,
  ]
}
