# SageMakerとS3の通信をAWSネットワーク内に閉じるためのVPCエンドポイント。
# 本番環境でのデータ漏洩リスクを低減
# 注意: デフォルトVPCへのアタッチで実装。専用VPCが必要な場合はVPCモジュールを別途作成すること

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_route_tables" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.prefix}-vpc-endpoints-sg"
  description = "SageMaker VPCエンドポイント用セキュリティグループ"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  tags = merge(var.common_tags, {
    Name = "${var.prefix}-vpc-endpoints-sg"
  })
}

resource "aws_vpc_endpoint" "sagemaker_api" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.region}.sagemaker.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.prefix}-sagemaker-api-endpoint"
  })
}

resource "aws_vpc_endpoint" "sagemaker_runtime" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.region}.sagemaker.runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.prefix}-sagemaker-runtime-endpoint"
  })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default.ids

  tags = merge(var.common_tags, {
    Name = "${var.prefix}-s3-endpoint"
  })
}
