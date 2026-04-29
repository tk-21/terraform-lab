# コスト異常をサービス単位で検知。個別サービスの急激なコスト増加をキャッチ
resource "aws_ce_anomaly_monitor" "service_monitor" {
  name         = "${var.prefix}-service-monitor"
  monitor_type = "DIMENSIONAL"

  monitor_dimension = "SERVICE"

  tags = var.common_tags
}

resource "aws_ce_anomaly_subscription" "ops_subscription" {
  name      = "${var.prefix}-ops-subscription"
  frequency = "IMMEDIATE"

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["50"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  monitor_arn_list = [aws_ce_anomaly_monitor.service_monitor.arn]

  # EventBridgeデフォルトバスに送信し、EventBridgeルールでStep Functionsへルーティング
  subscriber {
    address = "arn:aws:events:ap-northeast-1:${var.account_id}:event-bus/default"
    type    = "SNS"
  }

  tags = var.common_tags
}
