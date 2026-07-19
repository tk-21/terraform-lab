# Worker サービスのオートスケーリング（SQS キュー深度ベース）
resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  min_capacity       = 1
  max_capacity       = 10
}

resource "aws_appautoscaling_policy" "worker_scale_out" {
  name               = "deepdive-worker-scale-out"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      scaling_adjustment          = 2
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 40
      # キュー深度が閾値(10)+0〜40 の範囲: +2 タスク
    }
    step_adjustment {
      scaling_adjustment          = 5
      metric_interval_lower_bound = 40
      # キュー深度が閾値(10)+40 以上（実質 50+）のとき: +5 タスク
    }
  }
}

resource "aws_appautoscaling_policy" "worker_scale_in" {
  name               = "deepdive-worker-scale-in"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown        = 120
    # スケールインは慎重に: スケールアウトの 2 倍の cooldown
    metric_aggregation_type = "Average"

    step_adjustment {
      scaling_adjustment          = -1
      metric_interval_upper_bound = 0
    }
  }
}

# CloudWatch Alarm: スケールアウトトリガー（キュー深度 >= 10）
resource "aws_cloudwatch_metric_alarm" "sqs_scale_out" {
  alarm_name          = "deepdive-sqs-scale-out"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 10

  dimensions = {
    QueueName = "deepdive-job-queue"
  }

  alarm_actions = [aws_appautoscaling_policy.worker_scale_out.arn]
}

# CloudWatch Alarm: スケールイントリガー（キュー深度 < 5 が 2 分続いたら縮退）
resource "aws_cloudwatch_metric_alarm" "sqs_scale_in" {
  alarm_name          = "deepdive-sqs-scale-in"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 5

  dimensions = {
    QueueName = "deepdive-job-queue"
  }

  alarm_actions = [aws_appautoscaling_policy.worker_scale_in.arn]
}
