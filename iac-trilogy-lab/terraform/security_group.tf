# -----------------------------------------------------------------------
# EC2用セキュリティグループ
# -----------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${local.prefix}-app-sg"
  description = "EC2 app server security group"
  vpc_id      = aws_vpc.main.id

  # インバウンドルールなし（SSH禁止）
  # SSM Session Manager は EC2 エージェントからのアウトバウンド通信で動作するため
  # インバウンドポートの開放は不要

  # アウトバウンド: 全許可
  # SSM エンドポイント・S3・CloudWatch Logs への HTTPS 通信に必要
  egress {
    description = "全アウトバウンド通信を許可（SSM/S3/CloudWatch用）"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.prefix}-app-sg"
  }
}
