locals {
  common_tags = merge(var.common_tags, { Module = "ssm" })
  prefix      = "s3t-${var.environment}"
}

# ---------------------------------------------------------------------------
# CloudWatch Logs グループ — SSM セッションログ
# [セキュリティ] KMS CMK で保存データを暗号化。KMSキーポリシーで CloudWatch Logs サービスを許可済み
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ssm_sessions" {
  name              = "/aws/ssm/sessions/${local.prefix}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-ssm-sessions"
  })
}

# ---------------------------------------------------------------------------
# SSM ドキュメント — Session Manager セッション設定
# [セキュリティ] セッションログにより「誰が・いつ・何をしたか」を完全追跡可能
# ---------------------------------------------------------------------------
resource "aws_ssm_document" "session_manager" {
  name            = "SSM-SessionManagerRunShell-${local.prefix}"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager preferences for ${local.prefix}"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName               = var.session_logs_bucket_name
      s3KeyPrefix                = "sessions/"
      s3EncryptionEnabled        = true
      cloudWatchLogGroupName     = aws_cloudwatch_log_group.ssm_sessions.name
      cloudWatchEncryptionEnabled = true
      # [セキュリティ] 20分アイドルで自動切断
      idleSessionTimeout = "20"
      # [セキュリティ] 最大60分。長時間セッションによる不正操作リスクを低減
      maxSessionDuration = "60"
      kmsKeyId           = var.kms_key_arn
    }
  })

  tags = merge(local.common_tags, {
    Name = "SSM-SessionManagerRunShell-${local.prefix}"
  })

  depends_on = [aws_cloudwatch_log_group.ssm_sessions]
}

# ---------------------------------------------------------------------------
# SSM Parameter Store — アプリ用 DB 接続情報
# [設計意図] アプリは Parameter Store から DB 接続情報を取得。
#            パスワードは Secrets Manager から別途取得（責務分離）
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "db_endpoint" {
  name        = "/ata-prod/app/db_endpoint"
  description = "Aurora cluster writer endpoint"
  type        = "SecureString"
  value       = var.cluster_endpoint
  key_id      = var.kms_key_arn

  tags = merge(local.common_tags, {
    Name = "db-endpoint"
  })
}

resource "aws_ssm_parameter" "db_reader_endpoint" {
  name        = "/ata-prod/app/db_reader_endpoint"
  description = "Aurora cluster reader endpoint"
  type        = "SecureString"
  value       = var.reader_endpoint
  key_id      = var.kms_key_arn

  tags = merge(local.common_tags, {
    Name = "db-reader-endpoint"
  })
}

resource "aws_ssm_parameter" "db_port" {
  name        = "/ata-prod/app/db_port"
  description = "Aurora cluster port"
  type        = "String"
  value       = tostring(var.port)

  tags = merge(local.common_tags, {
    Name = "db-port"
  })
}

resource "aws_ssm_parameter" "db_name" {
  name        = "/ata-prod/app/db_name"
  description = "Aurora database name"
  type        = "String"
  value       = var.db_name

  tags = merge(local.common_tags, {
    Name = "db-name"
  })
}
