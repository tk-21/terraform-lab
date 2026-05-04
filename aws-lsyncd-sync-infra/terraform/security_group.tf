# =============================================================
# security_group.tf — EC2 セキュリティグループ
# master/slave 共用。
# 運用者アクセスは SSM Session Manager 経由のため、
# インターネットからのポート22を開けない。
# lsyncd の rsync over SSH は VPC 内プライベート IP のみ許可。
# =============================================================

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "lsyncd web sync - master and slave shared SG"
  vpc_id      = aws_vpc.main.id

  # VPC 内 master→slave の lsyncd rsync 用 SSH のみ許可
  # （インターネットからのポート22は開けない）
  ingress {
    description = "SSH from VPC for lsyncd rsync"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # nginx 動作確認用 HTTP
  ingress {
    description = "HTTP for nginx verification"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ec2-sg" }
}
