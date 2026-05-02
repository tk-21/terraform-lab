data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# KMS CMK — EBS / RDS / S3 / Secrets Manager 暗号化共通キー
# [セキュリティ] 年次自動ローテーションで長期間の鍵漏洩リスクを低減
# [設計意図] キーポリシーはルートアカウント管理権限のみ設定し、EC2ロールへのアクセスは
#            security モジュールの IAM ポリシーで委任制御する（循環依存を回避しつつ最小権限を実現）
# ---------------------------------------------------------------------------
resource "aws_kms_key" "main" {
  description             = "CMK for s3t-prod — EBS, RDS, S3, Secrets Manager encryption"
  key_usage               = "ENCRYPT_DECRYPT"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # [セキュリティ] ルートアカウントに管理権限を付与してキー孤立を防ぐ（必須設定）
        # EC2ロールはIAMポリシーでDecrypt/GenerateDataKeyのみ委任される
        Sid    = "EnableRootAccountAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # [セキュリティ] CloudWatch LogsのVPC Flow Logs暗号化に必要
        Sid    = "AllowCloudWatchLogsEncryption"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  # [注意] 削除するとEBS/RDS/Secrets Managerのデータが永久に失われる
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "s3t-prod-main"
  }
}

resource "aws_kms_alias" "main" {
  name          = "alias/s3t-prod-main"
  target_key_id = aws_kms_key.main.key_id
}
