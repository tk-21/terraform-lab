# =============================================================
# Aurora Serverless v2 (PostgreSQL 15) クラスター
#
# 設計判断:
# - Serverless v2 を選択した理由: ハンズオン環境での idle 時コスト最小化
#   (0.5 ACU ≒ $0.06/hr vs Provisioned db.t3.micro $0.017/hr だが
#    スケールアップ不要・運用シンプル)
# - Writer + Reader の 2 台構成: フェイルオーバー検証のため必須
# - DB Subnet のみに配置し App Subnet からの直接接続を禁止
# =============================================================

# ─── セキュリティグループ ──────────────────────────────────────
resource "aws_security_group" "aurora" {
  name        = "${var.prefix}-aurora-sg"
  description = "Aurora クラスター用 SG - RDS Proxy からの接続のみ許可"
  vpc_id      = var.vpc_id

  # インバウンドルールは別リソース（aws_security_group_rule）で管理する
  # Phase 3 rds-proxy モジュール・Phase 4 rotation モジュールが各自追加するため
  # インラインと外部ルールの混在コンフリクトを避ける

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "アウトバウンド全許可"
  }

  tags = { Name = "${var.prefix}-aurora-sg" }
}

# ─── DB Subnet Group ─────────────────────────────────────────
resource "aws_db_subnet_group" "aurora" {
  name       = "${var.prefix}-aurora-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = { Name = "${var.prefix}-aurora-subnet-group" }
}

# ─── パラメータグループ ────────────────────────────────────────
# デフォルトパラメータグループはカスタム変更不可のため必ず作成する
resource "aws_rds_cluster_parameter_group" "aurora" {
  family      = "aurora-postgresql15"
  name        = "${var.prefix}-aurora-pg15-params"
  description = "Aurora PostgreSQL 15 カスタムパラメータグループ"

  # 接続ログ有効化（障害調査・監査に必要）
  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  # スロークエリログ（1秒以上のクエリを記録）
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = { Name = "${var.prefix}-aurora-pg15-params" }
}

# ─── Aurora Cluster ───────────────────────────────────────────
resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.prefix}-aurora-cluster"
  engine             = "aurora-postgresql"
  engine_version     = "15.4"
  # Serverless v2 は engine_mode=provisioned + serverlessv2_scaling_configuration の組み合わせ
  engine_mode = "provisioned"

  database_name   = var.db_name
  master_username = var.db_master_username
  # AWS 管理の自動シークレット生成（Secrets Manager でパスワードを管理）
  manage_master_user_password = true

  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora.name

  # Serverless v2 スケーリング設定
  serverlessv2_scaling_configuration {
    min_capacity = var.min_acu # 0.5 ACU: idle 時の最小コスト
    max_capacity = var.max_acu # 4 ACU: ハンズオン上限
  }

  # バックアップ（dev でも 1 日は保持）
  backup_retention_period = 1
  preferred_backup_window = "17:00-18:00" # JST 02:00-03:00

  # 削除保護（Phase 6 の cleanup 時のみ一時解除）
  deletion_protection = true

  allow_major_version_upgrade = false
  # dev 環境は即時適用（メンテナンスウィンドウ待ち不要）
  apply_immediately = true

  # CloudWatch Logs エクスポート（PostgreSQLログをCWLに転送）
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # dev 環境: 削除時のスナップショット不要
  skip_final_snapshot = true

  tags = { Name = "${var.prefix}-aurora-cluster" }
}

# ─── Aurora Instances ─────────────────────────────────────────
# Writer インスタンス（ap-northeast-1a）
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  # Serverless v2 専用インスタンスクラス
  instance_class = "db.serverless"
  engine         = aws_rds_cluster.aurora.engine
  engine_version = aws_rds_cluster.aurora.engine_version

  availability_zone    = "${var.aws_region}a"
  db_subnet_group_name = aws_db_subnet_group.aurora.name

  # クエリ分析用（7日間無料期間あり）
  performance_insights_enabled = true
  # Enhanced Monitoring 1分間隔（RDS Proxy の接続プール監視に活用）
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  apply_immediately = true

  tags = { Name = "${var.prefix}-aurora-writer" }
}

# Reader インスタンス（ap-northeast-1c）
resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.prefix}-aurora-reader"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  availability_zone    = "${var.aws_region}c"
  db_subnet_group_name = aws_db_subnet_group.aurora.name

  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  apply_immediately = true

  tags = { Name = "${var.prefix}-aurora-reader" }
}

# ─── Enhanced Monitoring IAM Role ────────────────────────────
resource "aws_iam_role" "rds_monitoring" {
  # RDS Enhanced Monitoring が CloudWatch にメトリクスを書き込むためのロール
  name = "${var.prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.prefix}-rds-monitoring-role" }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
