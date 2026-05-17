locals {
  common_tags = merge(var.tags, {
    Project     = "aws-multilayer-firewall-terraform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  })
}

# -------------------------------------------------------------------
# AMI: Amazon Linux 2023 (arm64) - SSM Agent 同梱
# -------------------------------------------------------------------
data "aws_ami" "al2023" {
  # 設計理由: 最新の Amazon Linux 2023 を data で動的取得することで、
  # AMI ID のハードコードを避けパッチ済みイメージを常に使用できる。
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -------------------------------------------------------------------
# IAM: SSM 用 Instance Profile
# -------------------------------------------------------------------
resource "aws_iam_role" "ec2_ssm" {
  # SSM Agent の動作に必要な最小ポリシー。EC2 への直接 SSH は禁止。
  name = "${var.prefix}-role-ec2-ssm"

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

resource "aws_iam_role_policy_attachment" "ssm_core" {
  # 設計理由: AmazonSSMManagedInstanceCore は SSM Agent の動作に最低限必要な
  # マネージドポリシー。カスタムポリシーを書くより保守性が高く、
  # AWS が管理するため SSM の仕様変更にも追従する。
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.prefix}-profile-ec2-ssm"
  role = aws_iam_role.ec2_ssm.name

  tags = local.common_tags
}

# -------------------------------------------------------------------
# EC2: 検証用インスタンス
# -------------------------------------------------------------------
resource "aws_instance" "test" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t4g.nano"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  # 設計理由: IMDSv2 を強制することで、SSRF 脆弱性を利用した
  # メタデータ窃取攻撃（CVE-2019-* 系）を防ぐ。
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-ec2-test"
  })
}
