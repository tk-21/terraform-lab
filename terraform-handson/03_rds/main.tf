# =============================================================
# Step 3: RDS — マネージド MySQL
#
# 【学習ポイント】
#   - DB Subnet Group でマルチ AZ 配置の基盤を作る
#   - Security Group で EC2 からのみ DB 接続を許可する
#   - sensitive = true で機密変数（パスワード）を扱う
#   - RDS はプライベートサブネットに置いてインターネットから守る
# =============================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Environment = "handson"
    ManagedBy   = "terraform"
    Project     = var.prefix
  }
}

# -------------------------------------------------------------
# DB Subnet Group
# 【ポイント】
#   RDS は最低2つの AZ のサブネットが必要（マルチ AZ 対応のため）
#   プライベートサブネットを指定して外部からの直接アクセスを防ぐ
# -------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name        = "${var.prefix}-db-subnet-group"
  description = "Subnet group for RDS MySQL"
  subnet_ids  = var.private_subnet_ids # プライベートサブネット × 2 を指定

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-db-subnet-group"
  })
}

# -------------------------------------------------------------
# RDS 用 Security Group
# 【ポイント】
#   EC2 の Security Group ID を ingress の source として指定することで
#   「あの EC2 から来た通信だけ許可」という制御が可能
#   CIDR 指定より精密でセキュアな設計
# -------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.prefix}-rds-sg"
  description = "RDS security group - allow MySQL from EC2 only"
  vpc_id      = var.vpc_id

  # EC2 の SG からの MySQL 接続のみ許可
  ingress {
    description     = "MySQL from EC2 security group"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.ec2_security_group_id] # CIDR ではなく SG ID で絞る
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-rds-sg"
  })
}

# -------------------------------------------------------------
# RDS パラメータグループ
# 【ポイント】
#   文字コードを utf8mb4 に設定することで日本語・絵文字が扱える
#   デフォルトパラメータグループを使うと変更できないため独自で作成
# -------------------------------------------------------------
resource "aws_db_parameter_group" "mysql" {
  name        = "${var.prefix}-mysql-params"
  family      = "mysql8.0"
  description = "Custom parameter group for handson MySQL"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_client"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = local.common_tags
}

# -------------------------------------------------------------
# RDS インスタンス
# 【ポイント】
#   - multi_az = false: ハンズオンなのでシングル AZ（コスト削減）
#   - publicly_accessible = false: プライベートに配置
#   - skip_final_snapshot = true: destroy 時にスナップショットを取らない
#   - backup_retention_period = 0: 自動バックアップ無効（コスト削減）
# -------------------------------------------------------------
resource "aws_db_instance" "main" {
  # 識別子（AWS コンソール上の表示名）
  identifier = "${var.prefix}-mysql"

  # エンジン設定
  engine         = "mysql"
  engine_version = "8.0"

  # インスタンスサイズ（Free Tier: db.t3.micro）
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  # DB 初期設定
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password # sensitive 変数（planの出力でマスクされる）

  # ネットワーク設定
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.mysql.name

  # ハンズオン用設定（本番では変更すること）
  multi_az                = false # 本番: true
  publicly_accessible     = false # 本番: false のまま
  skip_final_snapshot     = true  # 本番: false
  deletion_protection     = false # 本番: true
  backup_retention_period = 0     # 本番: 7 以上

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-mysql"
  })
}
