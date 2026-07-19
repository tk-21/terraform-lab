locals {
  # リソース名の一貫性を保つため、プレフィックスをlocalsで集約する
  name_prefix = "${var.project}-${var.environment}"

  # Karpenterのサブネット自動検出に使用するディスカバリータグ値
  discovery_tag = "${var.project}-${var.environment}"

  # サブネット定義: AZ・CIDRの対応をlocalsで宣言することで変更時の修正箇所を最小化する
  azs = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]

  public_subnets = {
    "ap-northeast-1a" = "10.0.0.0/24"
    "ap-northeast-1c" = "10.0.1.0/24"
    "ap-northeast-1d" = "10.0.2.0/24"
  }

  private_subnets = {
    "ap-northeast-1a" = "10.0.16.0/20"
    "ap-northeast-1c" = "10.0.32.0/20"
    "ap-northeast-1d" = "10.0.48.0/20"
  }

  # VPC Endpoint専用サブネット: Interface Endpointはノードとは別のサブネットに分離することで
  # セキュリティグループ制御を明確にする
  endpoint_subnets = {
    "ap-northeast-1a" = "10.0.100.0/28"
    "ap-northeast-1c" = "10.0.100.16/28"
    "ap-northeast-1d" = "10.0.100.32/28"
  }

  # Interface型VPC Endpointの一覧
  # NAT Gatewayなしで各AWSサービスにアクセスするために必要なエンドポイントをすべて列挙する
  interface_endpoints = {
    ecr_api     = "com.amazonaws.ap-northeast-1.ecr.api"
    ecr_dkr     = "com.amazonaws.ap-northeast-1.ecr.dkr"
    sts         = "com.amazonaws.ap-northeast-1.sts"
    ec2         = "com.amazonaws.ap-northeast-1.ec2"
    logs        = "com.amazonaws.ap-northeast-1.logs"
    ssm         = "com.amazonaws.ap-northeast-1.ssm"
    ssmmessages = "com.amazonaws.ap-northeast-1.ssmmessages"
    elb         = "com.amazonaws.ap-northeast-1.elasticloadbalancing"
    aps         = "com.amazonaws.ap-northeast-1.aps"
    bedrock     = "com.amazonaws.ap-northeast-1.bedrock-runtime"
    eks         = "com.amazonaws.ap-northeast-1.eks"
  }

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  # プライベートDNSホスト名が有効でないとInterface VPC Endpointのプライベートホスト名解決に失敗する
  enable_dns_support = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# パブリックサブネット: ALBのみ配置。ノードは一切配置しない
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                     = "${local.name_prefix}-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  })
}

# プライベートサブネット: EKSノード配置。NAT GWなしでVPC Endpoint経由でAWSサービスにアクセスする
resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-${each.key}"
    # KarpenterがサブネットをAuto-discoveryするために必要なタグ
    "karpenter.sh/discovery"          = local.discovery_tag
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# VPC Endpoint専用サブネット: Interface Endpointをノードと分離することで
# エンドポイントへのアクセス制御をセキュリティグループで明確に管理する
resource "aws_subnet" "endpoint" {
  for_each = local.endpoint_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-endpoint-${each.key}"
  })
}

# Internet Gateway: パブリックサブネット(ALB)のみが使用する
# EKSノードはVPC Endpoint経由でAWSサービスにアクセスするため不要だが
# ALBのIngressのためにIGWが必要
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# パブリックサブネット用ルートテーブル
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# プライベートサブネット用ルートテーブル: デフォルトルートなし
# S3 Gateway Endpointのルートのみ追加する
resource "aws_route_table" "private" {
  for_each = local.private_subnets

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-rt-${each.key}"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# VPC Endpoint専用サブネット用ルートテーブル
resource "aws_route_table" "endpoint" {
  for_each = local.endpoint_subnets

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-endpoint-rt-${each.key}"
  })
}

resource "aws_route_table_association" "endpoint" {
  for_each = aws_subnet.endpoint

  subnet_id      = each.value.id
  route_table_id = aws_route_table.endpoint[each.key].id
}

# Interface VPC Endpoint用セキュリティグループ
# VPC内からの443のみを許可することで意図しないトラフィックを遮断する
resource "aws_security_group" "vpc_endpoint" {
  name        = "${local.name_prefix}-vpc-endpoint-sg"
  description = "VPC Endpoint用セキュリティグループ: VPC内からのHTTPS通信のみ許可"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "VPC内からのHTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "全アウトバウンド許可"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc-endpoint-sg"
  })
}

# S3 Gateway Endpoint: Gateway型はルートテーブルに追加する方式のため
# Interface型とは別扱いにする必要がある
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  vpc_endpoint_type = "Gateway"

  # プライベートサブネットとEndpoint専用サブネットの両方に関連付ける
  # これによりノードからもEndpointサブネットからもS3にアクセスできる
  route_table_ids = concat(
    [for rt in aws_route_table.private : rt.id],
    [for rt in aws_route_table.endpoint : rt.id]
  )

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-endpoint-s3"
  })
}

# Interface型VPC Endpoint: for_eachで一元管理することで追加・削除が容易になる
resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = aws_vpc.main.id
  service_name      = each.value
  vpc_endpoint_type = "Interface"
  # プライベートDNSを有効化することで既存コードの変更なしにEndpoint経由の通信が実現される
  private_dns_enabled = true

  subnet_ids         = [for s in aws_subnet.endpoint : s.id]
  security_group_ids = [aws_security_group.vpc_endpoint.id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-endpoint-${each.key}"
  })
}
