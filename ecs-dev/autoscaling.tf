# ECS Service Auto Scaling Target
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Target Tracking (CPU 50% を目標に自動調整)
# resource "aws_appautoscaling_policy" "cpu_target" {
#   name               = "${var.project}-${var.env}-cpu50"
#   policy_type        = "TargetTrackingScaling"
#   resource_id        = aws_appautoscaling_target.ecs.resource_id
#   scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
#   service_namespace  = aws_appautoscaling_target.ecs.service_namespace

#   target_tracking_scaling_policy_configuration {
#     predefined_metric_specification {
#       predefined_metric_type = "ECSServiceAverageCPUUtilization"
#     }

#     target_value       = 50
#     scale_in_cooldown  = 120
#     scale_out_cooldown = 60
#   }
# }

# Target Tracking (ALB RequestCountPerTarget)
resource "aws_appautoscaling_policy" "alb_rps_target" {
  name               = "${var.project}-${var.env}-alb-req-per-target"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"

      # app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id> 形式
      resource_label = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.this.arn_suffix}"
    }

    # 目標：ターゲット1台あたり 50 req/min
    # 例：全体 200 req/min なら desiredCount ~ 4 を狙うイメージ
    target_value       = 10
    scale_in_cooldown  = 120
    scale_out_cooldown = 30
  }
}
