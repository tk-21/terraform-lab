# Target Tracking Scaling Policy (CPU 50%)
resource "aws_autoscaling_policy" "cpu50" {
  name                   = "${local.base_name}-cpu50"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.web.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0

    # スケールインの揺れを抑える（実務だとONが多い）
    disable_scale_in = false
  }
}
