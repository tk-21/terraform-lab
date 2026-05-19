# =============================================================
# 疎通確認用EC2（完全プライベート）
# - SSHポート開放なし（Session Manager経由でアクセス）
# - NAT GW なし（VPC Endpoint経由でAWS APIに到達）
# - arm64（Graviton）でコスト最小化（t4g.nano: $0.0052/時）
# =============================================================

# S3 Gateway EndpointのPrefix List IDを動的に取得
# Gateway型はルートテーブルで動作するためSGのprefix_list_idsで制御できる
data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.ap-northeast-1.s3"
}

# SSM Session Manager使用のためのIAMロール
resource "aws_iam_role" "bastion" {
  name = "${local.prefix}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# Session Manager使用に必要な最低限のポリシー
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.prefix}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# EC2用セキュリティグループ（Inbound全拒否）
resource "aws_security_group" "bastion" {
  name        = "${local.prefix}-bastion-sg"
  description = "疎通確認用EC2 - SSMアウトバウンドのみ許可"
  vpc_id      = module.vpc.vpc_id

  # Inbound: 全拒否（SSHポート不要）
  # Session ManagerはEC2からのアウトバウンドのみで動作する

  egress {
    description     = "SSM Endpoint（Interface）への通信"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [module.endpoints.endpoint_security_group_id]
  }

  egress {
    description     = "S3 Endpoint（Gateway）への通信"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.s3.id]
  }

  egress {
    description     = "PrivateLink Consumer Endpoint経由でHub NginxへのHTTPアクセス"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    # Consumer EndpointのSGを宛先に指定することでベストプラクティスのSG間参照を実現
    security_groups = [aws_security_group.privatelink_consumer.id]
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-bastion-sg"
  })
}

# 最新Amazon Linux 2023 AMI（arm64）
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = "t4g.nano"
  subnet_id              = module.vpc.subnet_ids["private-1a"]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  # IMDSv2必須（IMDSv1はSSRFリスクがあるため無効化）
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-bastion"
  })
}

output "bastion_instance_id" {
  description = "Session Managerで接続する際のインスタンスID"
  value       = aws_instance.bastion.id
}
