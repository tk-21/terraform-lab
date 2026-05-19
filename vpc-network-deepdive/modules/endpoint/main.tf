# =============================================================
# Gateway型 VPC Endpoint（S3・DynamoDB）
# 実装: ルートテーブルにPrefix Listへのルートを自動追加する
# ENIを作成しないため、Security Groupは不要・追加コストゼロ
# Prefix List: pl-xxxxxx（AWSマネージドのIPレンジ集合）
# =============================================================
resource "aws_vpc_endpoint" "gateway" {
  for_each = var.gateway_endpoints

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type = "Gateway"

  # 対象のルートテーブルにPrefix Listへのルートを自動追加
  # privateサブネットのRTBを指定（publicは通常不要）
  route_table_ids = var.route_table_ids

  # ポリシーでアクセスを制限（デフォルトは全許可）
  # 本番ではS3バケット・DynamoDBテーブルを特定のARNに絞る
  policy = each.value.policy

  tags = merge(var.tags, {
    Name = "${var.prefix}-${each.key}-endpoint"
    Type = "Gateway"
  })
}

# =============================================================
# Interface型 VPC Endpoint（SSM・SSM Messages・EC2 Messages等）
# 実装: 指定サブネットにENI（Elastic Network Interface）を作成する
# → VPC内のプライベートIPでAWSサービスのAPIに到達可能になる
# → DNS名 (*.region.amazonaws.com) がENIのIPに解決される
#
# NAT GW不要でインターネット接続なしにAWS APIを呼べる理由:
# パケットがAWSバックボーンネットワーク内で完結するため
# =============================================================
resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id             = var.vpc_id
  service_name       = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = [aws_security_group.endpoint.id]

  # private_dns_enabled = true にすることで
  # ssm.ap-northeast-1.amazonaws.com がENIのプライベートIPに解決される
  # この設定にはVPCの enable_dns_hostnames = true が前提条件
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.prefix}-${each.key}-endpoint"
    Type = "Interface"
  })
}

# =============================================================
# Interface Endpoint用セキュリティグループ
# EC2からのHTTPS（443）のみ許可
# Endpoint側のSGで制御することでEC2側SG変更が不要
# =============================================================
resource "aws_security_group" "endpoint" {
  name        = "${var.prefix}-endpoint-sg"
  description = "VPC Interface Endpoint用SG - EC2からのHTTPS通信を許可"
  vpc_id      = var.vpc_id

  ingress {
    description = "EC2からのHTTPS（AWS API呼び出し）"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # VPC CIDR内からのみ許可
  }

  # Egress: AWSマネージドサービスへの通信はAWSバックボーン内で完結
  # 明示的なEgressルールは不要だが、デフォルトを削除しない
  egress {
    description = "Endpointからの応答トラフィック"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.prefix}-endpoint-sg"
  })
}
