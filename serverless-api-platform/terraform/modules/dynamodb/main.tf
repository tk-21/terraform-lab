# terraform/modules/dynamodb/main.tf
#
# DynamoDB Single Table Design の実装。
# CLAUDE.md の設計に基づき、GSI×2 + Streams + TTL + 暗号化 を設定する。

locals {
  # テーブル名をローカル変数で組み立て（ハードコード禁止）
  # 命名規則: sap-<env>-items
  table_name = "${var.prefix}-items"
}

# ============================================================
# なぜ PAY_PER_REQUEST（オンデマンド）を選択したか
# ============================================================
# サーバーレス API はトラフィックが予測困難なため、オンデマンドが最適。
# PROVISIONED モードでは事前にキャパシティを見積もる必要があり、
# スパイク時に ProvisionedThroughputExceededException が発生するリスクがある。
#
# PAY_PER_REQUEST を選択した場合、以下は不要になる:
#   - aws_appautoscaling_target（プロビジョンドキャパシティの自動スケール設定）
#   - aws_appautoscaling_policy（スケールアウト/イン ポリシー）
# これらは billing_mode = "PROVISIONED" 専用のリソースであり、
# PAY_PER_REQUEST では DynamoDB が自動でスループットを管理するため設定不要。
#
# 月額コスト目標 ~$3 以下に対して、トラフィックが少ない dev 環境では特に最適。
# prod でも初期フェーズはオンデマンドを維持し、安定したトラフィックパターンが
# 確認できた時点で PROVISIONED + Auto Scaling への移行を検討すること。

resource "aws_dynamodb_table" "items" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  # ============================================================
  # 属性定義
  # ============================================================
  # DynamoDB では、インデックスで使用する属性のみ定義すれば良い。
  # item_id, name, description 等の非キー属性はスキーマ定義不要。

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

  # GSI-1/GSI-2 共通のソートキー
  attribute {
    name = "created_at"
    type = "S"
  }

  # ============================================================
  # GSI-1: ユーザー別アイテム一覧
  # ============================================================
  # user_id でクエリし、created_at で降順ソートする（ScanIndexForward=false）。
  #
  # projection_type = "ALL" を選択した理由:
  # このインデックスはエンドユーザー向け一覧 API（GET /items）で使用する。
  # 一覧表示ではアイテムの全属性（name, description, status 等）を返すため、
  # ALL にしてメインテーブルへの追加クエリを省略することでレイテンシを最小化する。
  # ストレージコスト増加より UX 向上を優先する。
  global_secondary_index {
    name            = "user-index"
    hash_key        = "user_id"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  # ============================================================
  # GSI-2: ステータス別一覧（管理用）
  # ============================================================
  # status でクエリし、created_at で降順ソートする。
  #
  # projection_type = "INCLUDE" を選択した理由:
  # このインデックスは管理用途（ステータス別一覧・バッチ処理）のみに使用する。
  # ALL にするとすべての属性が GSI にコピーされストレージコストが増加する。
  # 管理画面の一覧表示に必要な最小限の属性（item_id, name, user_id）のみを射影し
  # ストレージコストを削減する。詳細表示が必要な場合は PK/SK で
  # メインテーブルを直接参照する（追加クエリが発生するが管理用途では許容範囲）。
  global_secondary_index {
    name               = "status-index"
    hash_key           = "status"
    range_key          = "created_at"
    projection_type    = "INCLUDE"
    non_key_attributes = ["item_id", "name", "user_id"]
  }

  # ============================================================
  # TTL（有効期限）
  # ============================================================
  # ARCHIVED アイテムを30日後に自動削除する。
  # expires_at は UNIX タイムスタンプ（秒）で設定する。
  # TTL による削除はストリームに NEW_AND_OLD_IMAGES として記録される。
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # ============================================================
  # DynamoDB Streams
  # ============================================================
  # 変更イベントを stream-processor Lambda に流し、
  # S3 に監査ログとして保存する。
  # NEW_AND_OLD_IMAGES で変更前後の値を両方取得することで、
  # 「何が」「どのように変わったか」を監査ログに記録できる。
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # ============================================================
  # PITR（ポイントインタイムリカバリ）
  # ============================================================
  # prod 環境では必須（var.enable_pitr = true）。
  # dev ではコスト削減のため無効化（デフォルト false）。
  # 過去35日間の任意の時点にテーブルを復元できる。
  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  # ============================================================
  # サーバーサイド暗号化（AWS マネージドキー）
  # ============================================================
  # enabled = true かつ kms_key_arn を省略すると、
  # AWS マネージドキー（alias/aws/dynamodb）が使用される。
  # カスタム KMS キーより管理コストが低く、追加料金も発生しない。
  # prod でカスタムキーによる独自管理が必要な場合は
  # var.kms_key_arn を追加して kms_key_arn に渡すこと。
  server_side_encryption {
    enabled = true
  }

  tags = var.tags
}

# ============================================================
# DAX（DynamoDB Accelerator）— prod のみ
# ============================================================
# DAX はインメモリキャッシュで読み取りレイテンシを μs に削減する。
# コストが高いため dev 環境では使用しない（enable_dax = false）。
resource "aws_dax_cluster" "this" {
  count = var.enable_dax ? 1 : 0

  cluster_name       = "${var.prefix}-dax"
  iam_role_arn       = aws_iam_role.dax[0].arn
  node_type          = "dax.t3.small"
  replication_factor = 1 # prod では 3 以上を推奨（Multi-AZ 冗長化）

  server_side_encryption {
    enabled = true
  }

  tags = var.tags
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

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "dax" {
  count      = var.enable_dax ? 1 : 0
  role       = aws_iam_role.dax[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}
