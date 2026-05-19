# =============================================================
# Spoke-ProdでHub公開サービスへのConsumer Interface Endpointを作成
# VPC Peeringなしでも、このEndpoint経由でHubのNginxにアクセス可能
# =============================================================

# Hub側のTerraform stateからService Nameを取得
# パスはenvs/spoke_prod/から見たenvs/hub/の相対パス
data "terraform_remote_state" "hub" {
  backend = "local"
  config = {
    path = "../hub/terraform.tfstate"
  }
}

# PrivateLinkのConsumer用SG
resource "aws_security_group" "privatelink_consumer" {
  name        = "${local.prefix}-pl-consumer-sg"
  description = "PrivateLink Consumer Endpoint用SG"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "EC2からのHTTPアクセス（Hubサービスへ）"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-pl-consumer-sg"
  })
}

# Consumer側Interface Endpoint
# このENIのIPにアクセスすることでHub NLB → Nginx にパケットが届く
resource "aws_vpc_endpoint" "hub_service" {
  vpc_id             = module.vpc.vpc_id
  service_name       = data.terraform_remote_state.hub.outputs.privatelink_service_name
  vpc_endpoint_type  = "Interface"
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [aws_security_group.privatelink_consumer.id]

  # カスタムPrivateLinkではDNSの自動解決が効かないため
  # private_dns_enabled = false にしてENIのIPで直接アクセスする
  # （Hub側でRoute53プライベートホストゾーンを設定すれば名前解決も可能）
  private_dns_enabled = false

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-hub-service-endpoint"
  })
}

output "hub_service_endpoint_dns" {
  description = "Hub Nginxにアクセスする際のDNS名（curlで確認）"
  value       = aws_vpc_endpoint.hub_service.dns_entry
}
