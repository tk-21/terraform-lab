# =============================================================================
# Computeモジュール
# 設計思想: EC2はTerraformで「存在」を管理し、内部設定はAnsibleに委譲する
# user_dataは最小限（SSMエージェント起動確認のみ）とし、
# ミドルウェア設定はAnsibleで行う
# =============================================================================

# 最新のAmazon Linux 2023 AMIを動的取得
# ハードコードしない理由: AMI IDはリージョン・時間によって変わるため
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# SSMセッションマネージャー用IAMロール
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.name_prefix}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# AmazonSSMManagedInstanceCoreのみアタッチ
# 理由: SSHを使わずSSMでアクセスするための最小権限セット
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# SSMパラメータ読み取り用インラインポリシー
# 理由: Ansibleが実行時にSSMパラメータを取得するための権限
resource "aws_iam_role_policy" "ssm_params_read" {
  name = "${var.name_prefix}-ssm-params-read"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.name_prefix}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.name_prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2_ssm.name
}

# EC2用セキュリティグループ
resource "aws_security_group" "ec2" {
  name        = "${var.name_prefix}-ec2-sg"
  description = "EC2インスタンス用: アウトバウンドのみ許可（SSM経由で管理）"
  vpc_id      = var.vpc_id

  # インバウンドルールなし: SSMセッションマネージャーはインバウンドポート不要
  # SSM接続の仕組み: EC2からSSMエンドポイントへのアウトバウンド443で実現

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "全アウトバウンド許可: パッケージ取得・SSM通信用"
  }

  tags = { Name = "${var.name_prefix}-ec2-sg" }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # user_dataは最小限: SSMエージェントの動作確認のみ
  # ミドルウェア（nginx等）のインストールはAnsibleで行う
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # SSMエージェントが起動していることを確認
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true  # 静止時暗号化: セキュリティ要件
    delete_on_termination = true
  }

  tags = {
    Name           = "${var.name_prefix}-web"
    Role           = "web"          # Ansible Dynamic Inventoryのフィルタリング用タグ
    AnsibleManaged = "true"         # Ansibleで管理対象であることを明示
  }
}
