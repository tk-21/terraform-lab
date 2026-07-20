# PAY_PER_REQUESTを選択する
# 理由: ハンズオン用途ではトラフィックが断続的のため、
#       プロビジョニングキャパシティより従量課金の方がコストが低い
resource "aws_dynamodb_table" "sensor_data" {
  name         = "${var.project_name}-table"
  billing_mode = "PAY_PER_REQUEST"

  # パーティションキー: device_id
  # 理由: センサーごとにデータを分散させ、ホットパーティションを避ける
  hash_key = "device_id"

  # ソートキー: timestamp
  # 理由: デバイスごとの時系列クエリを効率化するため
  range_key = "timestamp"

  attribute {
    name = "device_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  # TTLを設定する
  # 理由: ハンズオンデータが永続化されてコストが増加しないよう、
  #       72時間後に自動削除する
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Project = var.project_name
    Purpose = "センサーデータの永続化ストア"
  }
}
