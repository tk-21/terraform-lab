# Amazon Linux 2023 の最新AMIを自動取得
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# セキュリティグループ
resource "aws_security_group" "this" {
  name        = "${local.name_prefix}-ec2-sg"
  description = "EC2 Security Group for ${local.name_prefix}"
  vpc_id      = var.vpc_id

  # dynamic ブロック: var.ingress_rules のリストを展開してingressブロックを生成する
  # ルールを追加したいときは呼び出し側の ingress_rules 変数に追記するだけでよい
  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-sg"
  })
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]

  user_data = var.user_data != "" ? var.user_data : null

  lifecycle {
    # AMIは頻繁に更新されるが、再作成は不要なため変更を無視する
    ignore_changes = [ami]

    # EIPがアタッチされているため、先に新インスタンスを作ってからEIPを付け替える
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2"
  })
}

resource "aws_eip" "this" {
  instance = aws_instance.this.id
  domain   = "vpc"

  # インスタンス削除前にEIPをデタッチするため、依存関係を明示する
  depends_on = [aws_instance.this]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eip"
  })
}
