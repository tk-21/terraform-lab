# VPC Endpoint用セキュリティグループ (Interface Endpoint共通)
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project}-vpc-endpoints-sg"
  description = "VPC Interface Endpoints: HTTPS inbound from VPC only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "VPC内からのHTTPSのみ許可"
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

  tags = { Name = "${var.project}-vpc-endpoints-sg" }
}

# --- Interface Endpoints (for_each で一括作成) ---
# private_dns_enabled=true: サービス名のままDNS解決できるため、アプリ側の変更不要
locals {
  interface_endpoints = {
    # ECR APIエンドポイント: イメージのプッシュ・プル、メタデータ操作
    "ecr.api" = "com.amazonaws.${var.region}.ecr.api"
    # ECR Dockerレジストリ: 実際のレイヤーデータ転送
    "ecr.dkr" = "com.amazonaws.${var.region}.ecr.dkr"
    # CloudWatch Logs: ECS/EKSコンテナログの送信先
    "logs" = "com.amazonaws.${var.region}.logs"
    # SSM Parameter Store: シークレット・設定値の取得
    "ssm" = "com.amazonaws.${var.region}.ssm"
    # SSM Session Manager: ECS Exec / SSMセッション通信チャネル
    "ssmmessages" = "com.amazonaws.${var.region}.ssmmessages"
    # SSMエージェント ↔ Systems Manager間の制御メッセージ
    "ec2messages" = "com.amazonaws.${var.region}.ec2messages"
    # IAM STS: Pod Identity / ECSタスクロールの認証トークン取得
    "sts" = "com.amazonaws.${var.region}.sts"
    # SQS API: ワーカーのメッセージ受信・削除操作
    "sqs" = "com.amazonaws.${var.region}.sqs"
    # EC2 API: KarpenterがEC2インスタンスを作成・削除するために必要
    "ec2" = "com.amazonaws.${var.region}.ec2"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.project}-vpce-${each.key}" }
}

# --- Gateway Endpoints ---
# S3: ECRのレイヤーストレージ・EKS Bootstrapスクリプトの取得
# Gateway EndpointはルートテーブルにルートとしてInjectionされる (料金無料)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project}-vpce-s3" }
}
