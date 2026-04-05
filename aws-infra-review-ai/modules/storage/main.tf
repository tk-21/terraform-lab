# =============================================================================
# storage モジュール
#
# 役割:
#   1. input S3 バケット  - Terraform コード・アーキテクチャ図の入力ファイルを保存
#   2. reports S3 バケット - supervisor が生成した HTML レポートを保存（90日で自動削除）
#   3. DynamoDB テーブル  - 各エージェントの発言・議論ログ・レビュー履歴を記録
#
# 依存関係: なし（最も上流のモジュール）
# =============================================================================

data "aws_caller_identity" "current" {}

# =============================================================================
# S3: レビュー入力ファイル保存バケット
# ユーザーが Terraform コードまたはアーキテクチャ画像をアップロードする場所
# =============================================================================
resource "aws_s3_bucket" "input" {
  # バケット名はグローバルユニークにする必要があるため account ID を含める
  bucket = "${var.project_name}-input-${data.aws_caller_identity.current.account_id}"

  # 本番移行時は force_destroy = false に変更してデータ保護を強化
  force_destroy = true
}

# パブリックアクセスをすべてブロック（最小権限原則）
resource "aws_s3_bucket_public_access_block" "input" {
  bucket = aws_s3_bucket.input.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# サーバーサイド暗号化（SSE-S3）を有効化
resource "aws_s3_bucket_server_side_encryption_configuration" "input" {
  bucket = aws_s3_bucket.input.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# バージョニングを有効化（誤削除防止・監査証跡）
resource "aws_s3_bucket_versioning" "input" {
  bucket = aws_s3_bucket.input.id

  versioning_configuration {
    status = "Enabled"
  }
}

# =============================================================================
# S3: HTML レポート保存バケット
# report-generator が生成したレポートを保存、90日後に自動削除
# =============================================================================
resource "aws_s3_bucket" "reports" {
  bucket        = "${var.project_name}-reports-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ライフサイクルルール: 90日後にオブジェクトを自動削除（コスト最適化）
resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-reports-after-90-days"
    status = "Enabled"

    expiration {
      days = 90
    }

    # 不完全なマルチパートアップロードを7日後に削除
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# =============================================================================
# DynamoDB: 議論ログ・レビュー履歴テーブル
#
# スキーマ:
#   PK: session_id (String) - レビューセッションの一意ID
#   アトリビュート（後から追加）:
#     - input_type: "terraform" | "architecture"
#     - created_at: ISO8601 タイムスタンプ
#     - rounds: Map（各エージェントの発言・スーパーバイザーの統合）
#     - final_report_url: S3 レポート URL
# =============================================================================
resource "aws_dynamodb_table" "review_sessions" {
  name         = "${var.project_name}-review-sessions"
  billing_mode = "PAY_PER_REQUEST" # 検証環境: リクエスト課金でコスト最適化

  # PK のみで十分（セッション ID で一意特定可能）
  hash_key = "session_id"

  attribute {
    name = "session_id"
    type = "S"
  }

  # ポイントインタイムリカバリ（PITR）: 35日以内の任意時点に復元可能
  point_in_time_recovery {
    enabled = true
  }

  # 保存時暗号化（デフォルト AWS マネージドキー）
  server_side_encryption {
    enabled = true
  }

  # TTL: セッションデータを365日後に自動削除（DynamoDB Storage コスト削減）
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}
