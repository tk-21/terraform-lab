# =============================================================================
# EC2モジュール - App EC2 / Bastion EC2 / IAM Role 定義
# =============================================================================

# -----------------------------------------------------------------------------
# AMIデータソース - Amazon Linux 2023 arm64 最新を動的取得
# Graviton3 (arm64) を使用することでコスト削減を実現
# -----------------------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# IAM Role - App EC2用
# SSM経由でSSH鍵不要のセッション管理 + CloudWatchエージェントによるメトリクス・ログ収集
# =============================================================================

resource "aws_iam_role" "ec2" {
  name = "${var.project}-${var.environment}-ec2-role"

  # EC2サービスのみがこのRoleをAssumeできるように最小権限で設定
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project}-${var.environment}-ec2-role"
    Role = "app"
  }
}

# SSM Session Manager を使用してSSH鍵なしでEC2に接続するために必要
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent がメトリクス・ログをCloudWatchへ送信するために必要
resource "aws_iam_role_policy_attachment" "ec2_cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-${var.environment}-ec2-instance-profile"
  role = aws_iam_role.ec2.name
}

# =============================================================================
# IAM Role - Bastion用
# BastionはSSM接続のみに利用するため CloudWatchAgentServerPolicy は不要
# =============================================================================

resource "aws_iam_role" "bastion" {
  name = "${var.project}-${var.environment}-bastion-role"

  # EC2サービスのみがこのRoleをAssumeできるように最小権限で設定
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project}-${var.environment}-bastion-role"
    Role = "bastion"
  }
}

# SSM Session Manager 経由でBastionに接続するために必要（SSH不要）
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project}-${var.environment}-bastion-instance-profile"
  role = aws_iam_role.bastion.name
}

# =============================================================================
# App EC2 × 2台 - プライベートサブネットに配置
# ALBからのトラフィックのみ受け付け、直接インターネット公開はしない
# =============================================================================

resource "aws_instance" "app" {
  count = 2

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type_app
  subnet_id                   = var.private_subnet_ids[count.index]
  vpc_security_group_ids      = [var.app_sg_id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false # プライベートサブネットのためパブリックIPは不要

  # IMDSv2強制設定
  # http_tokens = "required" にすることでIMDSv1を無効化する
  # IMDSv1はSSRF脆弱性によって悪用される可能性があるため、必ずrequiredに設定すること
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true         # 保存データの暗号化を有効化
    delete_on_termination = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # SSM Agentの起動確認（AL2023ではデフォルトインストール済み）
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  tags = {
    Name = "${var.project}-${var.environment}-app-0${count.index + 1}"
    Role = "app"
  }
}

# =============================================================================
# Bastion EC2 × 1台 - パブリックサブネットに配置
# SSMのパブリックエンドポイントへ接続するためパブリックIPを付与
# SSH (port 22) は開放しない - SSM Session Manager経由でアクセス
# =============================================================================

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type_bastion
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [var.bastion_sg_id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true # SSMパブリックエンドポイントへの接続に必要

  # IMDSv2強制設定
  # Bastionも同様にIMDSv2を強制してSSRF脆弱性への悪用リスクを排除する
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # SSM Agentの起動確認（AL2023ではデフォルトインストール済み）
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  tags = {
    Name = "${var.project}-${var.environment}-bastion-01"
    Role = "bastion"
  }
}
