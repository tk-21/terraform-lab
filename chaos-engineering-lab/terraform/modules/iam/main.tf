locals {
  name_prefix = "${var.prefix}-${var.env}"
}

# ── EC2 インスタンスプロファイル ────────────────────────────────────────

# EC2 が SSM・CloudWatch と通信するための最小権限ロール
resource "aws_iam_role" "ec2_ssm" {
  name = "${local.name_prefix}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${local.name_prefix}-ec2-ssm-role" })
}

# SSM セッションマネージャー接続に必要な管理ポリシー
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent によるメトリクス送信に必要な管理ポリシー
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2_ssm.name

  tags = merge(var.tags, { Name = "${var.prefix}-ec2-instance-profile" })
}

# ── FIS 実行ロール ──────────────────────────────────────────────────────

# FIS が SSM SendCommand を使って EC2 に CPU 負荷を注入するロール
resource "aws_iam_role" "fis_execution" {
  name = "${var.prefix}-fis-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.prefix}-fis-execution-role" })
}

# 多層安全弁設計:
# Layer 1: FIS 停止条件（CPU 90% × 10 分でアラームトリガー → 自動停止）
# Layer 2: FIS アクション duration PT5M（5 分で自動終了）
# Layer 3: PERCENT(50) 選択（全インスタンスへの同時注入を防止）
# Layer 4: IAM 最小権限（FIS ロールは SSM SendCommand のみ許可）
resource "aws_iam_role_policy" "fis_execution" {
  name = "${var.prefix}-fis-execution-policy"
  role = aws_iam_role.fis_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",          # EC2 に stress-ng コマンドを送信
          "ssm:GetCommandInvocation", # コマンド実行状態の確認
          "ssm:ListCommands",
          "ssm:CancelCommand", # FIS 停止時のクリーンアップ
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",                 # FIS ターゲット EC2 を探索
          "autoscaling:DescribeAutoScalingGroups", # ASG 状態確認
          "autoscaling:DescribeAutoScalingInstances",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents", # FIS 実験ログを CloudWatch に書き込み
        ]
        Resource = "arn:aws:logs:ap-northeast-1:*:log-group:/aws/fis/*"
      },
      # FIS 実験ログの初回配信時に、CloudWatch Logs の配送設定と
      # 配信サービス用リソースポリシーを作成するために必要。
      # これらの API はロググループ ARN に限定できない。
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:DescribeLogGroups",
          "logs:DescribeResourcePolicies",
          "logs:PutResourcePolicy",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms", # 停止条件アラームを監視
        ]
        Resource = "*"
      },
    ]
  })
}
