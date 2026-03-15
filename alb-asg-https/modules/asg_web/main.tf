locals {
  base_name = var.name

  # private subnet は2つ使う（AZ分散）
  private_subnet_keys_2 = slice(sort(keys(var.private_subnet_ids)), 0, 2)
  selected_private_subnets = [
    for k in local.private_subnet_keys_2 : var.private_subnet_ids[k]
  ]

  # user_data に名前を埋める（簡易）
  user_data_rendered = replace(var.user_data, "$${NAME}", local.base_name)
}

# Amazon Linux 2023 の最新 AMI を取得（リージョン対応）
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_launch_template" "web" {
  name_prefix   = "${local.base_name}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [var.web_sg_id]

  # IMDSv2必須
  metadata_options {
    http_tokens = "required"
  }

  user_data = base64encode(local.user_data_rendered)

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${local.base_name}-web"
      Role = "web"
    })
  }

  tags = var.tags
}

resource "aws_autoscaling_group" "web" {
  name                      = "${local.base_name}-asg"
  min_size                  = var.asg_min_size
  desired_capacity          = var.asg_desired_capacity
  max_size                  = var.asg_max_size
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period

  vpc_zone_identifier = local.selected_private_subnets
  target_group_arns   = [var.target_group_arn]

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  # 置換が発生する変更に備えたローリング（実務向け）
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      max_healthy_percentage = 100
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

# --- CPU Target Tracking ---
resource "aws_autoscaling_policy" "cpu" {
  count                  = var.enable_cpu_target_tracking ? 1 : 0
  name                   = "${local.base_name}-cpu${var.cpu_target_value}"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.web.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_value
  }
}

# --- RequestCountPerTarget Target Tracking ---
resource "aws_autoscaling_policy" "reqcount" {
  count                  = var.enable_reqcount_target_tracking ? 1 : 0
  name                   = "${local.base_name}-reqcount"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.web.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.lb_arn_suffix}/${var.tg_arn_suffix}"
    }
    target_value = var.req_per_target
  }
}
