# Private subnet 内のワークロードが AWS API に私設経路で到達できるようにする。
resource "aws_security_group" "vpce" {
  name   = "${local.name}-vpce-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [aws_security_group.vpce.id]

  endpoints = {
    bedrock = {
      service             = "bedrock"
      private_dns_enabled = true
    }
    bedrock_runtime = {
      service             = "bedrock-runtime"
      private_dns_enabled = true
    }
    bedrock_agent = {
      service             = "bedrock-agent"
      private_dns_enabled = true
    }
    bedrock_agent_runtime = {
      service             = "bedrock-agent-runtime"
      private_dns_enabled = true
    }

    # EKS 上のアプリ運用で実質必須になる周辺サービスの endpoint。
    ecr_api = { service = "ecr.api", private_dns_enabled = true }
    ecr_dkr = { service = "ecr.dkr", private_dns_enabled = true }
    logs    = { service = "logs", private_dns_enabled = true }
    sts     = { service = "sts", private_dns_enabled = true }
    s3      = { service = "s3", service_type = "Gateway" }
  }

  tags = local.tags
}
