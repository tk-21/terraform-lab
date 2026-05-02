resource "random_password" "rds_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "rds_master" {
  name        = "ata-prod/rds/master-password"
  description = "RDS Aurora master password — ローテーション Lambda は Phase 3 で接続する"
  kms_key_id  = aws_kms_key.main.arn

  # [注意] Phase 3 で aws_secretsmanager_secret_rotation リソースを追加し rotation_lambda_arn を接続する
  # automatically_after_days = 30 のローテーションルールはその際に設定する

  recovery_window_in_days = 7

  tags = {
    Name = "ata-prod-rds-master-password"
  }
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.rds_master.result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# Secrets Manager ローテーション設定
# [設計意図] カスタム Lambda を作らず AWS 管理 Lambda を使うことで運用コストを削減
# [注意] ローテーション Lambda は事前に Aurora クラスター同一 VPC 内にデプロイが必要。
#        コンソールで「ローテーションを有効にする」を実行すると自動デプロイされる。
#        Lambda がデプロイ済みでない場合は apply がエラーになるためコメントアウトして
#        Lambda デプロイ後に有効化すること。
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret_rotation" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id

  # [設計意図] Aurora MySQL 用 AWS 管理ローテーション Lambda (同一アカウントにデプロイ済み前提)
  rotation_lambda_arn = "arn:aws:lambda:ap-northeast-1:${data.aws_caller_identity.current.account_id}:function:SecretsManagerMySQLRotationSingleUser"

  rotation_rules {
    automatically_after_days = 30
    duration                 = "2h"
  }
}
