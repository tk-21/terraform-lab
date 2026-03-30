# terraform/modules/dynamodb/main.tf
#
# DynamoDB Single Table Design の実装。
# CLAUDE.md の設計に基づき、GSI×2 + Streams + TTL を設定する。

resource "aws_dynamodb_table" "items" {
  # 命名規則: sap-<env>-items
  name         = "${var.prefix}-items"
  billing_mode = "PAY_PER_REQUEST" # オンデマンドキャパシティ（コスト最適化）
  hash_key     = "PK"
  range_key    = "SK"

  # ============================================================
  # 属性定義
  # ============================================================
  # DynamoDB では、インデックスで使用する属性のみ定義すれば良い。
  # item_id, name, description 等はスキーマ定義不要。

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  # GSI-1: ユーザー別アイテム一覧（created_at 降順ソート）
  attribute {
    name = "user_id"
    type = "S"
  }

  # GSI-2: ステータス別一覧（管理用）
  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  # ============================================================
  # GSI-1: ユーザー別アイテム一覧
  # ============================================================
  # user_id でクエリし、created_at で降順ソートする。
  # DynamoDB では降順ソートは ScanIndexForward=false で指定する。
  global_secondary_index {
    name            = "user-index"
    hash_key        = "user_id"
    range_key       = "created_at"
    projection_type = "ALL" # 全属性を射影（追加コストあり、クエリ効率優先）
  }

  # ============================================================
  # GSI-2: ステータス別一覧（管理用）
  # ============================================================
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  # ============================================================
  # TTL（有効期限）
  # ============================================================
  # ARCHIVED アイテムを30日後に自動削除する。
  # expires_at は UNIX タイムスタンプ（秒）で設定する。
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # ============================================================
  # DynamoDB Streams
  # ============================================================
  # 変更イベントを stream-processor Lambda に流し、
  # S3 に監査ログとして保存する。
  # NEW_AND_OLD_IMAGES で変更前後の値を両方取得する。
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # ============================================================
  # PITR（ポイントインタイムリカバリ）
  # ============================================================
  # prod 環境では必須。dev ではコスト削減のため無効化。
  point_in_time_recovery {
    enabled = var.enable_pitr
  }
}

# ============================================================
# DAX（DynamoDB Accelerator）— prod のみ
# ============================================================
# DAX はインメモリキャッシュで読み取りレイテンシを μs に削減する。
# コストが高いため dev 環境では使用しない。
# enable_dax = true の場合のみリソースを作成する。
resource "aws_dax_cluster" "this" {
  count = var.enable_dax ? 1 : 0

  cluster_name       = "${var.prefix}-dax"
  iam_role_arn       = aws_iam_role.dax[0].arn
  node_type          = "dax.t3.small"
  replication_factor = 1 # prod では 3 以上を推奨

  server_side_encryption {
    enabled = true
  }
}

resource "aws_iam_role" "dax" {
  count = var.enable_dax ? 1 : 0
  name  = "${var.prefix}-dax-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dax.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dax" {
  count      = var.enable_dax ? 1 : 0
  role       = aws_iam_role.dax[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}
