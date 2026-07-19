# Config Recorder — 全リソース変更を記録する中央設定
resource "aws_config_configuration_recorder" "main" {
  name     = "csar-config-recorder"
  role_arn = var.config_service_role_arn

  recording_group {
    # 全リソースタイプを記録する (対象を絞るとConfig Rulesが機能しないケースがある)
    all_supported = true
    # IAMユーザーはグローバルリソースのため include_global_resource_types=true が必須
    include_global_resource_types = true
  }
}

# Delivery Channel — 設定スナップショット・変更通知の配信先
resource "aws_config_delivery_channel" "main" {
  name           = "csar-config-delivery"
  s3_bucket_name = var.audit_bucket_name
  s3_key_prefix  = "config-snapshots"

  snapshot_delivery_properties {
    # 24時間ごとにスナップショットをS3へ配信する
    delivery_frequency = "TwentyFour_Hours"
  }

  # RecorderがないとDelivery Channelは作成不可
  depends_on = [aws_config_configuration_recorder.main]
}

# Recorderを有効化する (Delivery Channel作成後でないと有効化できない)
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}
