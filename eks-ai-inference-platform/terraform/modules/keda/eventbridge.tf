# ────────────────────────────────────────────────
# EventBridge ルール: GPU Spot ノードの起動/終了イベント
# ────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "gpu_node_events" {
  name        = "${local.name_prefix}-gpu-node-events"
  description = "GPU Spot ノード (g4dn/g5) の起動/終了イベントをスケール通知Lambdaへ転送する"

  event_pattern = jsonencode({
    "source" : ["aws.ec2"],
    "detail-type" : ["EC2 Instance State-change Notification"],
    "detail" : {
      # runningとterminatedのみに絞る: stopping/stopped/shutting-downは通知不要
      # GPUノードのフィルタリングはinstance-typeがイベントに含まれないためLambda側で行う
      "state" : ["running", "terminated"]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "scale_notify_lambda" {
  rule      = aws_cloudwatch_event_rule.gpu_node_events.name
  target_id = "ScaleNotifyLambda"
  arn       = aws_lambda_function.scale_notify.arn
}
