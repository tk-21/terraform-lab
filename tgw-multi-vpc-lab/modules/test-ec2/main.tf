# ─────────────────────────────────────────
# 疎通確認専用のEC2インスタンス
# SSMアクセスのため、IAMロールとVPCエンドポイントが必要
# コスト最小化: t4g.nano + Spot
# ─────────────────────────────────────────

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
}

resource "aws_iam_role" "ssm" {
  name = "${var.instance_name}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, { Name = "${var.instance_name}-ssm-role" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.instance_name}-ssm-profile"
  role = aws_iam_role.ssm.name
}

resource "aws_security_group" "ec2" {
  name        = "${var.instance_name}-sg"
  description = "Test EC2 SG - allow ICMP from private ranges"
  vpc_id      = var.vpc_id

  # ICMPを内部レンジから許可（疎通確認用）
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.instance_name}-sg" })
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t4g.nano" # arm64 / Graviton2
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # Spot: コスト削減のため
  instance_market_options {
    market_type = "spot"
  }

  tags = merge(var.tags, { Name = var.instance_name })
}
