# terraform/modules/storage/main.tf
#
# 監査ログ用 S3 バケット。
# DynamoDB Streams → stream-processor Lambda → ここに保存される。
#
# 監査ログの保持設計:
#   - 目的: コンプライアンス・インシデント調査・変更履歴の追跡
#   - 保持期間: 7年（一般的な会計・監査要件に基づく。法令要件に応じて調整）
#   - 削除防止: バケットポリシーで DeleteObject を全員に拒否する。
#               ただし S3 ライフサイクルポリシーによる自動削除は
#               バケットポリシーをバイパスするため保持期間後は自動削除される。
#   - コスト最適化: 参照頻度に応じてストレージクラスを段階的に移行する

# ============================================================
# KMS キー（監査ログの保存に使用）
# ============================================================
# AES256（SSE-S3）ではなく KMS を使用する理由:
#   - KMS は誰がいつデータにアクセスしたかの操作ログを CloudTrail に残せる
#   - S3 の暗号化キーへのアクセスを IAM で細かく制御できる
#   - 監査ログ自体のアクセス制御を強化するため KMS が適切
resource "aws_kms_key" "audit_logs" {
  description             = "KMS key for ${var.prefix}-audit-logs S3 bucket encryption"
  deletion_window_in_days = 7
  # 年次自動ローテーション: キーマテリアルを1年ごとに更新してセキュリティを維持する
  enable_key_rotation = true

  tags = var.tags
}

resource "aws_kms_alias" "audit_logs" {
  name          = "alias/${var.prefix}-audit-logs"
  target_key_id = aws_kms_key.audit_logs.key_id
}

# ============================================================
# S3 バケット本体
# ============================================================
resource "aws_s3_bucket" "audit_logs" {
  # 命名規則: sap-<env>-audit-logs-<account_id>
  # account_id をサフィックスに付けることでグローバル一意性を保証する
  bucket = "${var.prefix}-audit-logs-${var.account_id}"

  tags = var.tags
}

# ============================================================
# パブリックアクセスの完全ブロック
# ============================================================
# 監査ログは外部公開してはならないため全設定を true にする
resource "aws_s3_bucket_public_access_block" "audit_logs" {
  bucket                  = aws_s3_bucket.audit_logs.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ============================================================
# バージョニング
# ============================================================
# バージョニングを有効化することで:
#   - 上書きされたログの旧バージョンを保持できる
#   - 誤った上書きからの復元が可能
resource "aws_s3_bucket_versioning" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ============================================================
# KMS 暗号化
# ============================================================
resource "aws_s3_bucket_server_side_encryption_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit_logs.arn
    }
    # バケットキーを有効化することで KMS API コール数を削減しコストを最適化する
    # （S3 はオブジェクトごとに KMS を呼ぶのではなくバケットキーを使い回す）
    bucket_key_enabled = true
  }
}

# ============================================================
# ライフサイクルポリシー
# ============================================================
# 監査ログは初期以降ほとんど参照されないため、段階的に安価なストレージに移行する。
#
# ストレージクラスの移行タイムライン:
#   0〜90日:  STANDARD      → インシデント対応で頻繁に参照する可能性がある期間
#   91〜365日: STANDARD_IA  → 参照頻度が下がるがまだアクセスが必要な期間（90日後）
#   366日〜:   GLACIER       → 長期保存・コンプライアンス目的のみ（365日後）
#   7年後:     削除           → 一般的な監査ログの最大保持期間
#
# STANDARD_IA の注意点: 最低128KB・30日保存の課金単位があるため、
# 小さいファイルを多数保存する場合は STANDARD より高くなる場合がある。
resource "aws_s3_bucket_lifecycle_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  # パブリックアクセスブロックより後に作成する（依存関係）
  depends_on = [aws_s3_bucket_versioning.audit_logs]

  rule {
    id     = "audit-log-tiered-storage"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      # 7年後に削除（2555日 = 365 × 7）
      # コンプライアンス要件に応じて変更すること
      days = 2555
    }

    # バージョニングが有効なため、旧バージョンのライフサイクルも設定する
    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# ============================================================
# バケットポリシー（削除禁止・HTTPS 強制）
# ============================================================
# 監査ログの改ざん・削除を防ぐためのポリシー。
#
# DenyDeleteAuditLogs について:
#   全プリンシパル（管理者含む）の DeleteObject を拒否する。
#   これによりユーザーによる意図的・誤った削除を防止する。
#   ただし S3 ライフサイクルポリシーによる自動削除は
#   バケットポリシーの適用外となるため（S3 内部処理）、
#   7年後の自動削除は正常に機能する。
# ============================================================
# Lambda デプロイパッケージ用 S3 バケット
# ============================================================
# Lambda 関数の zip パッケージをここに保存する。
# 各関数のパッケージは source_code_hash による変更検知で差分更新される。
# 古いバージョンはライフサイクルポリシーで自動削除してコストを削減する。
resource "aws_s3_bucket" "lambda_deployment" {
  # 命名規則: sap-<env>-lambda-deployment-<account_id>
  bucket = "${var.prefix}-lambda-deployment-${var.account_id}"

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "lambda_deployment" {
  bucket                  = aws_s3_bucket.lambda_deployment.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "lambda_deployment" {
  bucket = aws_s3_bucket.lambda_deployment.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lambda_deployment" {
  bucket = aws_s3_bucket.lambda_deployment.id
  rule {
    apply_server_side_encryption_by_default {
      # デプロイパッケージは SSE-S3（AES256）で十分。
      # 監査ログと異なりキーアクセスログが不要なため KMS は使用しない。
      sse_algorithm = "AES256"
    }
  }
}

# 古いデプロイパッケージのバージョンを30日後に削除してコストを削減する。
# 現行バージョンは保持する（ロールバック用途に備える）。
resource "aws_s3_bucket_lifecycle_configuration" "lambda_deployment" {
  bucket = aws_s3_bucket.lambda_deployment.id

  depends_on = [aws_s3_bucket_versioning.lambda_deployment]

  rule {
    id     = "delete-old-deployment-packages"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ============================================================
# バケットポリシー（audit_logs）
# ============================================================
resource "aws_s3_bucket_policy" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  # public_access_block の設定が完了してからポリシーを適用する
  depends_on = [aws_s3_bucket_public_access_block.audit_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 監査ログの削除を全プリンシパルに禁止する
        # 管理者であっても手動削除できない設計とすることで
        # ログの完全性（Integrity）を保証する
        Sid       = "DenyDeleteAuditLogs"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
        ]
        Resource = "${aws_s3_bucket.audit_logs.arn}/*"
      },
      {
        # HTTPS 以外の通信を禁止する（通信経路上の盗聴・改ざん防止）
        Sid       = "EnforceHTTPS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.audit_logs.arn,
          "${aws_s3_bucket.audit_logs.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}
