locals {
  common_tags = merge(var.common_tags, { Module = "database" })
  prefix      = "s3t-${var.environment}"
}

# [設計意図] Secrets Managerと手動統合してローテーションを完全制御するためデータソースで取得
data "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = var.rds_secret_arn
}

resource "random_id" "snapshot_suffix" {
  byte_length = 4
}

# ---------------------------------------------------------------------------
# DB サブネットグループ — data tier subnets のみ使用
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name        = "${local.prefix}-db-subnet-group"
  description = "Subnet group for ${local.prefix} Aurora cluster — data tier only"
  subnet_ids  = var.data_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-db-subnet-group"
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Logs グループ — Aurora 監査/エラー/スロークエリログ
# [セキュリティ] 監査ログにより「誰が・いつ・何のSQLを実行したか」を完全追跡可能
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "aurora_audit" {
  name              = "/aws/rds/cluster/${local.prefix}-aurora-cluster/audit"
  retention_in_days = 90

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-aurora-audit-logs"
  })
}

resource "aws_cloudwatch_log_group" "aurora_error" {
  name              = "/aws/rds/cluster/${local.prefix}-aurora-cluster/error"
  retention_in_days = 30

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-aurora-error-logs"
  })
}

resource "aws_cloudwatch_log_group" "aurora_slowquery" {
  name              = "/aws/rds/cluster/${local.prefix}-aurora-cluster/slowquery"
  retention_in_days = 30

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-aurora-slowquery-logs"
  })
}

# ---------------------------------------------------------------------------
# RDS Aurora MySQL Serverless v2 クラスター
# ---------------------------------------------------------------------------
resource "aws_rds_cluster" "main" {
  cluster_identifier = "${local.prefix}-aurora-cluster"

  engine         = "aurora-mysql"
  engine_version = "8.0.mysql_aurora.3.04.0"
  database_name  = "appdb"

  master_username = "admin"
  # [設計意図] Secrets Managerと手動統合してローテーションを完全制御
  manage_master_user_password = false
  master_password             = jsondecode(data.aws_secretsmanager_secret_version.rds_master.secret_string)["password"]

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]

  # [セキュリティ] KMS CMK で保存データを暗号化
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  # [注意] ハンズオン終了時は false に変更してから terraform destroy を実行
  deletion_protection = var.deletion_protection

  backup_retention_period      = 7
  preferred_backup_window      = "17:00-18:00"      # UTC (JST 02:00-03:00)
  preferred_maintenance_window = "sun:18:00-sun:19:00" # UTC (JST 月曜03:00-04:00)

  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.prefix}-aurora-final-${random_id.snapshot_suffix.hex}"

  # [セキュリティ] 監査ログを CloudWatch Logs に送信。後でアラート設定可能
  enabled_cloudwatch_logs_exports = ["audit", "error", "slowquery"]

  serverlessv2_scaling_configuration {
    # [コスト] 最小0.5 ACU。アイドル時のコスト削減
    min_capacity = var.min_capacity
    # [設計意図] 本番初期は4ACU上限。負荷に応じて引き上げ
    max_capacity = var.max_capacity
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-aurora-cluster"
  })

  lifecycle {
    # [注意] 本番データ保護
    prevent_destroy = true
    # Secrets Manager ローテーション後の差分を無視
    ignore_changes = [master_password]
  }

  depends_on = [
    aws_cloudwatch_log_group.aurora_audit,
    aws_cloudwatch_log_group.aurora_error,
    aws_cloudwatch_log_group.aurora_slowquery,
  ]
}

# ---------------------------------------------------------------------------
# ライターインスタンス
# ---------------------------------------------------------------------------
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.main.id

  # [設計意図] db.serverless = Serverless v2 インスタンスクラス
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.main.engine
  engine_version       = aws_rds_cluster.main.engine_version
  db_subnet_group_name = aws_db_subnet_group.main.name

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-aurora-writer"
    Role = "writer"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# リーダーインスタンス
# [設計意図] リーダーエンドポイントをアプリの読み取りに使いライターの負荷を下げる
# ---------------------------------------------------------------------------
resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${local.prefix}-aurora-reader"
  cluster_identifier = aws_rds_cluster.main.id

  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.main.engine
  engine_version       = aws_rds_cluster.main.engine_version
  db_subnet_group_name = aws_db_subnet_group.main.name

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-aurora-reader"
    Role = "reader"
  })

  lifecycle {
    prevent_destroy = true
  }
}
