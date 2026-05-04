locals {
  tags = merge(var.tags, { Module = "ses-config" })
}

# ============================================================
# SES Configuration Set
# ============================================================

resource "aws_sesv2_configuration_set" "main" {
  # Configuration Set: 送信メールにトラッキングとイベント通知を付与する設定グループ
  # 送信時に ConfigurationSetName を指定することでメトリクスが収集される
  configuration_set_name = "mail-handson-config-set"

  delivery_options {
    # TLSポリシー: REQUIRE で送信時の暗号化を強制（平文SMTPを禁止）
    tls_policy = "REQUIRE"
  }

  reputation_options {
    # レピュテーションメトリクス有効: バウンス率・苦情率をCloudWatchに自動送信
    # Reputation.BounceRate / Reputation.ComplaintRate でモニタリング可能
    reputation_metrics_enabled = true
  }

  sending_options {
    sending_enabled = true
  }

  tags = local.tags
}

# ============================================================
# イベント転送先（バウンス → SNS）
# ============================================================

resource "aws_sesv2_configuration_set_event_destination" "bounce_sns" {
  # バウンスイベントをSNSトピック経由でbounce_handler Lambdaに転送する
  # SNSを挟むことで Fan-out パターンが実現できる（将来的にSlack通知等への分岐も可能）
  configuration_set_name = aws_sesv2_configuration_set.main.configuration_set_name
  event_destination_name = "bounce-to-sns"

  event_destination {
    enabled              = true
    matching_event_types = ["BOUNCE"]

    sns_destination {
      topic_arn = var.bounce_sns_topic_arn
    }
  }
}

# ============================================================
# イベント転送先（苦情 → SNS）
# ============================================================

resource "aws_sesv2_configuration_set_event_destination" "complaint_sns" {
  # 苦情イベントを別SNSトピックに転送する
  # バウンスと独立したトピックにすることでアラートしきい値や処理ロジックを別管理できる
  configuration_set_name = aws_sesv2_configuration_set.main.configuration_set_name
  event_destination_name = "complaint-to-sns"

  event_destination {
    enabled              = true
    matching_event_types = ["COMPLAINT"]

    sns_destination {
      topic_arn = var.complaint_sns_topic_arn
    }
  }
}

# ============================================================
# イベント転送先（全イベント → CloudWatch）
# ============================================================

resource "aws_sesv2_configuration_set_event_destination" "cloudwatch" {
  # 送受信・開封・クリックなど全イベントをCloudWatchメトリクスとして記録する
  # ダッシュボード構築とレピュテーション監視に使用する
  configuration_set_name = aws_sesv2_configuration_set.main.configuration_set_name
  event_destination_name = "all-events-to-cloudwatch"

  event_destination {
    enabled              = true
    matching_event_types = ["SEND", "DELIVERY", "BOUNCE", "COMPLAINT", "OPEN", "CLICK", "REJECT"]

    cloud_watch_destination {
      dimension_configuration {
        default_dimension_value = "not_defined"
        dimension_name          = "ses:from-domain"
        dimension_value_source  = "EMAIL_HEADER"
      }
    }
  }
}
