locals {
  # 既存の local.base_name がある前提
  # compute_alb.tf で作っている selected_public_subnets をそのまま使う想定
  # もし compute_alb.tf 側にあるなら、この locals は不要
  asg_subnet_ids = [for _, id in local.selected_public_subnets : id]
}

# UserData（AL2023 + nginx）
locals {
  web_user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf -y update
    dnf -y install nginx
    cat >/usr/share/nginx/html/index.html <<HTML
    <html>
      <body>
        <h1>${local.base_name}</h1>
        <p>autoscaling: true</p>
        <p>instance: $(hostname)</p>
      </body>
    </html>
    HTML
    systemctl enable --now nginx
  EOF
}

resource "aws_launch_template" "web" {
  name_prefix   = "${local.base_name}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = base64encode(local.web_user_data)

  # IMDSv2 推奨（実務向け）
  metadata_options {
    http_tokens = "required"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.base_name}-web"
      Role = "web"
    }
  }
}

resource "aws_autoscaling_group" "web" {
  name                = "${local.base_name}-asg"
  min_size            = var.asg_min_size
  desired_capacity    = var.asg_desired_capacity
  max_size            = var.asg_max_size
  vpc_zone_identifier = [for _, id in module.network.private_subnet_ids : id]

  health_check_type         = "ELB"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  # ALB TargetGroup に ASG を紐付け（これで自動登録）
  target_group_arns = [aws_lb_target_group.web.arn]

  # 置き換え時のダウンタイムを避ける
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.base_name}-web"
    propagate_at_launch = true
  }
  tag {
    key                 = "Role"
    value               = "web"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
