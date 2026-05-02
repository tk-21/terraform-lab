# [コスト] arm64 (Graviton) アーキテクチャを使用。x86_64比で最大20%コスト削減
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ---------------------------------------------------------------------------
# Launch Template
# ---------------------------------------------------------------------------
resource "aws_launch_template" "web" {
  name        = "s3t-prod-web-lt"
  description = "Launch template for s3t-prod web tier — arm64, IMDSv2 required"

  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = var.ec2_instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.ec2_sg_id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  # [セキュリティ] IMDSv1 を無効化。IMDSv1 は SSRF 攻撃でクレデンシャル漏洩するリスクがある
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # CloudWatch Agentのインストール（Ansibleで後から設定するが初期インストールはここで）
    dnf install -y amazon-cloudwatch-agent

    # SSMエージェントの確認（AL2023はデフォルトインストール済みだが念のため）
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent

    # Ansibleが後でアプリをデプロイするためのディレクトリ準備
    mkdir -p /opt/app
    chown ec2-user:ec2-user /opt/app
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.common_tags, {
      Name        = "s3t-prod-web"
      Module      = "compute"
      Role        = "webserver"
      Environment = var.environment
      Project     = "secure-3tier-iac-pipeline"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.common_tags, {
      Name   = "s3t-prod-web-ebs"
      Module = "compute"
    })
  }

  tags = merge(local.common_tags, {
    Name = "s3t-prod-web-lt"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Auto Scaling Group
# ---------------------------------------------------------------------------
resource "aws_autoscaling_group" "web" {
  name = "s3t-prod-web-asg"

  # [設計意図] 最小2台で単一障害点排除。3AZに分散配置
  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.web.arn]

  # [設計意図] ALBのヘルスチェック結果でASGが異常インスタンスを判断・置換する
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  # [設計意図] ローリング更新でダウンタイムなし
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  # Ansible 動的インベントリ用タグ — aws_ec2 プラグインが Role=webserver でグループ自動形成する
  dynamic "tag" {
    for_each = merge(var.common_tags, {
      Name        = "s3t-prod-web"
      Role        = "webserver"
      Environment = var.environment
      Project     = "secure-3tier-iac-pipeline"
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# ---------------------------------------------------------------------------
# スケーリングポリシー — Target Tracking (CPU)
# [コスト] 70%ではなく60%にすることで応答性を確保しながらコスト抑制
# ---------------------------------------------------------------------------
resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "s3t-prod-web-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}
