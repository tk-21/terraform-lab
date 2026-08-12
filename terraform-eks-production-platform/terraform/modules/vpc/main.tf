################################################################################
# VPCモジュール - メインリソース定義
#
# 3層ネットワーク設計：
#   Public    : ALB・NAT Gateway配置。インターネットからアクセス可能
#   Private   : EKS Node・Pod配置。NAT経由でアウトバウンドのみ可能
#   Isolated  : RDS・ElastiCache配置。インターネットアクセス完全遮断
################################################################################

################################################################################
# VPC
################################################################################

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # EKS は内部でDNS名前解決を使うため両方有効にする必須設定。
  # enable_dns_support    : VPC内のDNS解決を有効化
  # enable_dns_hostnames  : インスタンスにDNSホスト名を付与
  # これらがないとEKSノードがAPIサーバーやサービスを名前解決できない。
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc"
    # EKSがロードバランサー配置先のVPCを検索するために使用するタグ
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-cluster" = "shared"
  })
}

################################################################################
# サブネット
################################################################################

# パブリックサブネット（ALB・NAT Gateway用）
# map_public_ip_on_launch=true にする理由：
# Bastionホストや一時的なデバッグ用インスタンスが直接インターネットアクセスできるよう
# パブリックIPを自動割り当てにする。EKSノードはPrivateサブネットに配置するため影響なし。
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-public-${var.availability_zones[count.index]}"
    # EKS Load Balancer Controllerがパブリックロードバランサーを配置するサブネットを
    # 自動検索するために必要なタグ。このタグがないとALBが正しいサブネットに配置されない。
    "kubernetes.io/role/elb"                                               = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-cluster" = "shared"
  })
}

# プライベートサブネット（EKS Node・Pod用）
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-${var.availability_zones[count.index]}"
    # EKS Load Balancer Controllerが内部ロードバランサーを配置するサブネットを
    # 自動検索するために必要なタグ。
    "kubernetes.io/role/internal-elb"                                      = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-cluster" = "shared"
    # Karpenterがノード起動時にサブネットを検索するためのタグ
    "karpenter.sh/discovery" = "${var.project_name}-${var.environment}-cluster"
  })
}

# 分離サブネット（RDS・ElastiCache用）
# Privateとは別に分離する理由：
# RDS等のマネージドサービスをEKSノードと同じサブネットに置くと、
# ノードのセキュリティグループ設定ミスでDBに直接アクセスできるリスクがある。
# 完全に分離したサブネットにすることでネットワークレベルの防御を実現する。
resource "aws_subnet" "isolated" {
  count = length(var.isolated_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.isolated_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-isolated-${var.availability_zones[count.index]}"
  })
}

################################################################################
# インターネットゲートウェイ
################################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-igw"
  })
}

################################################################################
# Elastic IP（NAT Gateway用）
################################################################################

# NAT GatewayにはElastic IPが必要。
# AZごとにNAT Gatewayを作成する場合はAZ数分のEIPが必要。
# enable_nat_gateway_per_az=falseの場合はAZ1のみに1つ作成（コスト削減）。
resource "aws_eip" "nat" {
  count = var.enable_nat_gateway_per_az ? length(var.availability_zones) : 1

  domain = "vpc"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-eip-${count.index + 1}"
  })

  # IGWが作成されてからEIPを関連付けることを保証する
  depends_on = [aws_internet_gateway.this]
}

################################################################################
# NAT Gateway
################################################################################

# NAT GatewayをAZごとに配置する理由：
# NAT Gatewayが1つだけだとそのAZが障害時に全プライベートサブネットの
# アウトバウンド通信が停止する。AZごとに配置することでAZ障害を耐える。
# コスト: NAT Gateway は約$32/月/個 + データ転送料。2AZで約$65/月。
# 検証目的で enable_nat_gateway_per_az=false にすると1つに削減可能。
resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway_per_az ? length(var.availability_zones) : 1

  allocation_id = aws_eip.nat[count.index].id
  # NAT GatewayはPublicサブネットに配置する
  subnet_id = aws_subnet.public[count.index].id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-${var.availability_zones[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

################################################################################
# ルートテーブル
################################################################################

# パブリックサブネット用ルートテーブル
# デフォルトルートをIGWに向けることでインターネット接続を実現する
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-rtb-public"
  })
}

# プライベートサブネット用ルートテーブル（AZごとに分離）
# AZごとに別ルートテーブルを作成する理由：
# NAT GatewayをAZごとに配置した場合、各AZのプライベートサブネットは
# 同じAZのNAT Gatewayを経由するルートが必要。
# 共通ルートテーブルにすると特定のAZのNAT GWに集中してAZ間転送料が発生する。
resource "aws_route_table" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    # enable_nat_gateway_per_az=falseの場合は0番目（唯一の）NAT GWを使用
    nat_gateway_id = var.enable_nat_gateway_per_az ? aws_nat_gateway.this[count.index].id : aws_nat_gateway.this[0].id
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-rtb-private-${var.availability_zones[count.index]}"
  })
}

# 分離サブネット用ルートテーブル（デフォルトルートなし）
# Isolatedサブネットはインターネットへの経路を持たせない。
# RDS等はAWS内部のエンドポイント（VPC Endpoint経由）のみ使用するため
# デフォルトルートは不要。ルートを追加しないことで誤設定を防ぐ。
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id

  # ルートを追加しないことでインターネットへの経路を遮断

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-rtb-isolated"
  })
}

################################################################################
# ルートテーブルアソシエーション
################################################################################

resource "aws_route_table_association" "public" {
  count = length(var.public_subnet_cidrs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(var.private_subnet_cidrs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "isolated" {
  count = length(var.isolated_subnet_cidrs)

  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

################################################################################
# VPC Endpoint用セキュリティグループ
################################################################################

# Interface型VPC EndpointはENIを作成するため、
# トラフィックを制御するセキュリティグループが必要。
# VPC内からのHTTPS(443)のみ許可する理由：
# AWS API呼び出しはすべてHTTPSのため443のみで十分。
# VPC CIDRに限定することでVPC外からのアクセスを防ぐ。
resource "aws_security_group" "vpc_endpoint" {
  name        = "${var.project_name}-${var.environment}-sg-vpc-endpoint"
  description = "Security group for Interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Allow HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # アウトバウンドは制限しない（AWSサービスへの応答が必要）
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-sg-vpc-endpoint"
  })
}

################################################################################
# VPC Endpoints
#
# VPC Endpointを使用する理由（コスト・セキュリティの両面）：
# [コスト] ECRイメージPull時、NAT Gateway経由だとデータ転送料が高額になる。
#          ECR DKR Endpoint経由にするとNAT Gateway料金($0.045/GB)を回避できる。
# [セキュリティ] Privateサブネット内で通信が完結するため、
#               インターネットへのトラフィックが不要になる。
################################################################################

# S3 Gateway Endpoint
# Gateway型はENIを作成せずルートテーブルにエントリを追加する仕組み。
# 料金無料かつECRのイメージレイヤーはS3に保存されているため必須。
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.this.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"
  # Gateway型はルートテーブルに設定する
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.public.id],
    aws_route_table.private[*].id,
    [aws_route_table.isolated.id]
  )

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-s3"
  })
}

# ECR API Endpoint
# プライベートサブネットからECRへの認証APIリクエストをVPC内で完結させる。
# これがないと `docker login` に相当する認証がインターネット経由になる。
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint.id]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-ecr-api"
  })
}

# ECR DKR Endpoint（Docker Registry）
# コンテナイメージのPull（レイヤーダウンロード）をVPC内で完結させる。
# ECR API Endpointと併用が必要。
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint.id]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-ecr-dkr"
  })
}

# Secrets Manager Endpoint
# PodからSecrets Managerで機密情報を取得する際にVPC内で完結させる。
# IRSA + Secrets Manager CSI Driverの組み合わせで使用する。
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint.id]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-secretsmanager"
  })
}

# STS Endpoint
# IRSAはSTSのAssumeRoleWithWebIdentityを使用してPodにIAM認証情報を付与する。
# STS EndpointがないとプライベートサブネットからのIRSAが動作しない。
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint.id]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-sts"
  })
}

# CloudWatch Logs Endpoint
# Container InsightsがログをCloudWatch Logsに送信するために使用。
# Endpoint なしではNAT Gateway経由となり、ログ量が多い環境でコストが増加する。
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint.id]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-logs"
  })
}

################################################################################
# データソース
################################################################################

data "aws_region" "current" {}
