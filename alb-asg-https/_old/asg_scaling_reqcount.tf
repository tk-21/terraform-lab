variable "req_per_target" {
  type        = number
  description = "1ターゲットあたりのリクエスト数（/min）目標"
  default     = 100
}

resource "aws_autoscaling_policy" "reqcount" {
  name                   = "${local.base_name}-reqcount"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.web.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"

      resource_label = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.web.arn_suffix}"
    }

    target_value = var.req_per_target
  }
}
