locals {
  name_prefix = "${var.prefix}-${var.env}"
}

# Amazon Linux 2023 の最新 AMI を動的に取得する
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

# ── Launch Template ─────────────────────────────────────────────────────

resource "aws_launch_template" "main" {
  name_prefix = "${local.name_prefix}-lt-"
  description = "chaos-engineering-lab EC2 Launch Template"

  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [var.ec2_sg_id]

  # IMDSv2 を強制する（セキュリティ設計: SSRF 攻撃によるメタデータ漏洩防止）
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  monitoring {
    enabled = true
  }

  # EC2 インスタンスプロファイル（SSM エージェント通信に必要）
  # Phase 3 の IAM モジュール完了後に有効化する
  dynamic "iam_instance_profile" {
    for_each = var.instance_profile_name != "" ? [1] : []
    content {
      name = var.instance_profile_name
    }
  }

  # stress-ng と ヘルスチェックエンドポイントをセットアップする
  user_data = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    prefix = var.prefix
    env    = var.env
  }))

  # インスタンスにタグを付与する
  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${local.name_prefix}-ec2" })
  }

  # EBS ボリュームにタグを付与する
  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${local.name_prefix}-ebs" })
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-lt" })

  lifecycle {
    create_before_destroy = true
  }
}

# ── Auto Scaling Group ──────────────────────────────────────────────────

resource "aws_autoscaling_group" "main" {
  name                      = "${local.name_prefix}-asg"
  min_size                  = var.min_size
  desired_capacity          = var.desired_capacity
  max_size                  = var.max_size
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [var.target_group_arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  # ローリングアップデートで最小 50% のインスタンスを稼働させながら更新する
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = "${local.name_prefix}-asg" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Target Tracking Scaling Policy ──────────────────────────────────────

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${local.name_prefix}-target-tracking-policy"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  # FIS で CPU ストレスを注入すると CPUUtilization が急上昇し、
  # このポリシーがスケールアウトをトリガーする。
  # 2 台中 1 台への 100% 負荷（ASG 平均 CPU 約 50%）を検証できる値にする。
  # これがカオス実験の観測ポイント。
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 40.0
  }
}
