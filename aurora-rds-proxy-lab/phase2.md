# ✅Phase 2 — Aurora Serverless v2 構築

## 前フェーズ確認

```bash
cd terraform/environments/dev
terraform output  # vpc_id, subnet_ids が出力されていること
```

## このフェーズのゴール

- Aurora PostgreSQL 15 Serverless v2 クラスター（Writer + Reader、2 AZ 構成）を構築
- カスタムパラメータグループを作成し接続ログを有効化
- セキュリティグループで RDS Proxy からの接続のみに限定

---

## Step 2-1: Aurora モジュール

### `terraform/modules/aurora/variables.tf`

```hcl
variable "prefix"               {}
variable "vpc_id"               {}
variable "db_subnet_ids"        { type = list(string) }
variable "app_sg_id"            { description = "RDS Proxy の SG ID（後で差し替え）" }
variable "aws_region"           { default = "ap-northeast-1" }
variable "db_name"              { default = "appdb" }
variable "db_master_username"   { default = "dbadmin" }
variable "min_acu"              { default = 0.5 }
variable "max_acu"              { default = 4 }
```

### `terraform/modules/aurora/main.tf`

```hcl
# =============================================================
# Aurora Serverless v2 (PostgreSQL 15) クラスター
#
# 設計判断:
# - Serverless v2 を選択した理由: ハンズオン環境での idle 時コスト最小化
#   (0.5 ACU = ~$0.06/hr vs Provisioned db.t3.micro ~$0.017/hr だが
#    スケールアップ不要・運用シンプル)
# - Writer + Reader の 2 台構成: フェイルオーバー検証のため必須
# - DB Subnet のみに配置し App Subnet からの直接接続を禁止
# =============================================================

# ─── セキュリティグループ ──────────────────────────────────────
resource "aws_security_group" "aurora" {
  name   = "${var.prefix}-aurora-sg"
  vpc_id = var.vpc_id

  # RDS Proxy SG からの PostgreSQL 接続のみ許可
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.app_sg_id] # Phase 3 で RDS Proxy SG に変更
    description     = "RDS Proxyからの接続のみ許可（直接接続禁止）"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
  family = "aurora-postgresql15"
  name   = "${var.prefix}-aurora-pg15-params"

  # 接続ログ有効化（障害調査・監査に必要）
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  # スロークエリログ（1秒以上）
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

# ─── Aurora Cluster ───────────────────────────────────────────
resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.prefix}-aurora-cluster"
  engine             = "aurora-postgresql"
  engine_version     = "15.4"
  engine_mode        = "provisioned" # Serverless v2 は engine_mode=provisioned

  database_name   = var.db_name
  master_username = var.db_master_username
  # master_password は Secrets Manager が管理するため manage_master_user_password を使用
  manage_master_user_password = true # AWS 管理の自動シークレット生成

  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora.name

  # Serverless v2 スケーリング設定
  serverlessv2_scaling_configuration {
    min_capacity = var.min_acu  # 0.5 ACU: idle 時の最小コスト
    max_capacity = var.max_acu  # 4 ACU: ハンズオン上限（本番は要件に応じて増やす）
  }

  # バックアップ（dev でも 1 日は保持）
  backup_retention_period   = 1
  preferred_backup_window   = "17:00-18:00" # JST 02:00-03:00

  # 削除保護（cleanup 時に一時的に解除）
  deletion_protection = true

  # マイナーバージョン自動アップグレード
  allow_major_version_upgrade = false
  apply_immediately           = true # dev 環境は即時適用

  # CloudWatch Logs エクスポート
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # スナップショット管理
  skip_final_snapshot = true # dev 環境のみ
}

# ─── Aurora Instances ─────────────────────────────────────────
# Writer インスタンス（ap-northeast-1a）
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless" # Serverless v2 専用クラス
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  availability_zone            = "${var.aws_region}a"
  db_subnet_group_name         = aws_db_subnet_group.aurora.name
  performance_insights_enabled = true # クエリ分析（無料期間あり）
  monitoring_interval          = 60   # Enhanced Monitoring 1分間隔
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  apply_immediately = true
}

# Reader インスタンス（ap-northeast-1c）
resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.prefix}-aurora-reader"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  availability_zone            = "${var.aws_region}c"
  db_subnet_group_name         = aws_db_subnet_group.aurora.name
  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  apply_immediately = true
}

# ─── Enhanced Monitoring IAM Role ────────────────────────────
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ─── Outputs ─────────────────────────────────────────────────
output "cluster_id"              { value = aws_rds_cluster.aurora.id }
output "cluster_endpoint"        { value = aws_rds_cluster.aurora.endpoint }
output "cluster_reader_endpoint" { value = aws_rds_cluster.aurora.reader_endpoint }
output "aurora_sg_id"            { value = aws_security_group.aurora.id }
output "master_secret_arn"       { value = aws_rds_cluster.aurora.master_user_secret[0].secret_arn }
output "db_name"                 { value = aws_rds_cluster.aurora.database_name }
output "db_master_username"      { value = aws_rds_cluster.aurora.master_username }
```

---

## Step 2-2: environments/dev/main.tf に追記

```hcl
module "aurora" {
  source = "../../modules/aurora"

  prefix          = var.prefix
  vpc_id          = module.networking.vpc_id
  db_subnet_ids   = module.networking.private_db_subnet_ids
  aws_region      = var.aws_region

  # Phase 3 で RDS Proxy SG に差し替える（暫定: VPC Endpoint SG で代用）
  app_sg_id = module.networking.vpc_endpoint_sg_id
}

output "aurora_cluster_endpoint" {
  value = module.aurora.cluster_endpoint
}
output "aurora_reader_endpoint" {
  value = module.aurora.cluster_reader_endpoint
}
```

---

## Step 2-3: 実行・検証

```bash
cd terraform/environments/dev
terraform fmt -recursive
terraform validate
terraform plan
terraform apply  # Aurora 起動に 5-10 分かかる

# クラスター状態確認
aws rds describe-db-clusters \
  --db-cluster-identifier arpl-aurora-cluster \
  --query 'DBClusters[0].{Status:Status,Engine:Engine,EngineVersion:EngineVersion,ServerlessV2ScalingConfiguration:ServerlessV2ScalingConfiguration}' \
  --output json

# インスタンス確認
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=arpl-aurora-cluster" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Class:DBInstanceClass,AZ:AvailabilityZone,Status:DBInstanceStatus}' \
  --output table
```

### ACU メトリクス確認

```bash
# CloudWatch でServerlessV2ScalingConfiguration の ACU 使用量を確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ServerlessDatabaseCapacity \
  --dimensions Name=DBClusterIdentifier,Value=arpl-aurora-cluster \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average \
  --output table
```

---

## Step 2-4: ADR 記述

### `docs/adr/001-aurora-serverless-v2.md` を完成させる

```markdown
## Decision
<!-- 以下を参考に自分の言葉で記述する -->
<!-- - なぜ db.t3.micro などの Provisioned ではないか -->
<!-- - Serverless v2 の min_capacity 0.5 ACU にした判断根拠 -->
<!-- - manage_master_user_password を使った理由 -->

## Consequences
<!-- - ACU のスケーリング遅延（数秒程度）は許容できるか -->
<!-- - コスト予測: idle 時 0.5 ACU × $0.12/ACU-hr × 24h = ~$1.44/日 -->
<!-- - Enhanced Monitoring の監視間隔選択理由 -->
```

---

## フェーズ完了チェック

- [ ] Aurora クラスターが `available` 状態
- [ ] Writer (1a) / Reader (1c) の 2 インスタンスが起動
- [ ] CloudWatch Logs に `postgresql` ログが出力されている
- [ ] `master_secret_arn` が Secrets Manager に存在する
- [ ] `terraform fmt` / `terraform validate` 適用済み
- [ ] ADR 001 の Decision/Consequences を自分の言葉で記述

## 口頭説明チェック（Phase 2）

以下を5分で説明できること:

1. Aurora Serverless v2 の ACU とは何か、どうスケールするか
2. `engine_mode = "provisioned"` なのに Serverless v2 と呼ぶ理由
3. `manage_master_user_password = true` の動作（誰がシークレットを作るか）