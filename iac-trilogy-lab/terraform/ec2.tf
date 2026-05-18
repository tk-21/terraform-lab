# -----------------------------------------------------------------------
# AMI動的取得: Amazon Linux 2023 (arm64)
# -----------------------------------------------------------------------
data "aws_ami" "al2023_arm64" {
  most_recent = true
  # amazon 公式AMIのみを対象にする（サードパーティAMIの混入防止）
  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# -----------------------------------------------------------------------
# IAM ロール (EC2用・最小権限)
# -----------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name        = "${local.prefix}-ec2-role"
  description = "EC2インスタンス用IAMロール（SSM接続・S3アクセス）"

  # EC2サービスがこのロールを引き受けることを許可するトラストポリシー
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
    Name = "${local.prefix}-ec2-role"
  }
}

# SSM Session Manager で接続するための最低限のポリシー
# AmazonSSMManagedInstanceCore: SSMエージェント動作・セッション開始・ログ送信に必要
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# S3 アクセス用インラインポリシー
# 管理ポリシーではなくインラインポリシーを使う理由:
#   このロール専用の権限であり、他ロールと共有する予定がないため
resource "aws_iam_role_policy" "ec2_s3" {
  name = "${local.prefix}-ec2-s3-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ArtifactsBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        # バケット名を明示して最小権限を保証（全S3バケットへのアクセスを禁止）
        Resource = [
          "arn:aws:s3:::${local.artifacts_bucket_name}",
          "arn:aws:s3:::${local.artifacts_bucket_name}/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------
# IAM Instance Profile
# -----------------------------------------------------------------------
resource "aws_iam_instance_profile" "ec2" {
  name = "${local.prefix}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Name = "${local.prefix}-ec2-profile"
  }
}

# -----------------------------------------------------------------------
# EC2 インスタンス
# -----------------------------------------------------------------------
resource "aws_instance" "app" {
  ami           = data.aws_ami.al2023_arm64.id
  instance_type = "t4g.nano"

  # arm64 (Graviton2) を選択: x86_64比で約20%コスト削減・同等性能
  # t4g.nano は検証ラボ用途に十分。本番移行時は t4g.small へのスケールアップを検討

  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    # IMDSv2 を強制: IMDSv1 は SSRF 攻撃によるメタデータ漏洩リスクがある
    # http_tokens = "required" により、セッショントークンなしのリクエストを拒否
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    # ルートボリュームを暗号化（デフォルト暗号化が無効な場合に備えて明示）
    encrypted = true
  }

  # SSMエージェント起動確認用 user_data
  # Amazon Linux 2023 では SSM エージェントはデフォルトインストール済みだが
  # 起動時の状態確認と自動起動設定を保証するために明示的に実行する
  user_data = base64encode(<<-EOT
    #!/bin/bash
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
    echo "SSM Agent started at $(date)" >> /var/log/user-data.log
  EOT
  )

  tags = {
    Name = "${local.prefix}-app"
  }
}
