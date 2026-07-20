# オンデマンドモードを選択する
# 理由: シャード数を事前見積もりせずにコスト最適化できる。
#       ハンズオン用途では流量が予測しにくいため。
resource "aws_kinesis_stream" "sensor" {
  name = "${var.project_name}-stream"
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  # 保持期間は24時間 (デフォルト) で十分
  # 理由: ハンズオン用途では再処理より即時処理を重視する
  retention_period = 24

  tags = {
    Project = var.project_name
    Purpose = "IoTセンサーデータのリアルタイムストリーム"
  }
}
