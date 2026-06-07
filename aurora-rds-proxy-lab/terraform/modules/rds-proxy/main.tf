# =============================================================
# RDS Proxy 設計方針:
# - ECS タスクは DB エンドポイントを直接知らなくてよい
#   → アプリコードを変えずにフェイルオーバーが透過的に処理される
# - IAM 認証のみ: 接続文字列にパスワードを含めない
# - TLS 必須: 平文接続を拒否する
# - 接続プール: Lambda/Fargate の大量同時接続による Aurora 接続枯渇を防止
# =============================================================

# ─── RDS Proxy 用セキュリティグループ ─────────────────────────
resource "aws_security_group" "proxy" {
  name   = "${var.prefix}-rds-proxy-sg"
  vpc_id = var.vpc_id

  # アプリ層（Private App Subnet CIDR）からの PostgreSQL 接続を許可
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.10.0/24", "10.0.11.0/24"] # Private App Subnet
    description = "ECS Fargateタスクからの接続"
  }

  # Aurora SG への接続（Proxy → Aurora）
  egress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.aurora_sg_id]
    description     = "Aurora Clusterへの接続"
  }

  tags = { Name = "${var.prefix}-rds-proxy-sg" }
}

# Aurora SG のインバウンドを RDS Proxy SG に限定（Phase 2 で暫定設定した SG を置き換え）
resource "aws_security_group_rule" "aurora_from_proxy" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.proxy.id
  security_group_id        = var.aurora_sg_id
  description              = "RDS Proxy SGからのみ接続許可"
}

# ─── Secrets Manager の Proxy 用シークレット参照 ──────────────
# Proxy は master_user_secret（Phase 2 で作成）を参照して Aurora に接続する
# アプリは proxy に IAM 認証トークンで接続し、proxy が Aurora パスワード認証を代行
data "aws_secretsmanager_secret" "master" {
  arn = var.master_secret_arn
}

# ─── IAM Role for RDS Proxy ───────────────────────────────────
resource "aws_iam_role" "proxy" {
  name = "${var.prefix}-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Proxy が Secrets Manager からパスワードを取得するための権限
resource "aws_iam_role_policy" "proxy_secrets" {
  name = "${var.prefix}-proxy-secrets-policy"
  role = aws_iam_role.proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetSecretValue"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        # master secret と Phase 4 で作成するアプリ用 secret の両方
        Resource = [
          var.master_secret_arn,
          "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:arpl/*"
        ]
      },
      {
        Sid    = "DecryptSecret"
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        # Secrets Manager のデフォルト AWS マネージドキーはリソース ARN が事前不明のため * を使用
        # Condition で secretsmanager 経由のみに限定することで実質的な最小権限を担保
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ─── RDS Proxy ────────────────────────────────────────────────
resource "aws_db_proxy" "main" {
  name                   = "${var.prefix}-rds-proxy"
  debug_logging          = false # 本番では false（接続内容がログに出る可能性）
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800 # 30分アイドルで接続切断
  require_tls            = true # 平文接続を拒否
  role_arn               = aws_iam_role.proxy.arn
  vpc_security_group_ids = [aws_security_group.proxy.id]
  vpc_subnet_ids         = var.db_subnet_ids

  auth {
    auth_scheme               = "SECRETS"
    iam_auth                  = "REQUIRED" # IAM 認証必須（パスワード直接指定不可）
    secret_arn                = var.master_secret_arn
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
  }

  tags = { Name = "${var.prefix}-rds-proxy" }
}

# ─── Proxy Target Group（Aurora クラスターに向ける）─────────
resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.main.name

  connection_pool_config {
    # 最大接続数の 100% を Proxy がプール（Aurora max_connections の 100%）
    connection_borrow_timeout    = 120 # 接続待ち最大 120 秒
    max_connections_percent      = 100
    max_idle_connections_percent = 50 # idle 接続は 50% まで保持
  }
}

resource "aws_db_proxy_target" "aurora" {
  db_proxy_name         = aws_db_proxy.main.name
  target_group_name     = aws_db_proxy_default_target_group.main.name
  db_cluster_identifier = var.cluster_id
}

# ─── Reader Endpoint（読み取り分散用）──────────────────────────
resource "aws_db_proxy_endpoint" "reader" {
  db_proxy_name          = aws_db_proxy.main.name
  db_proxy_endpoint_name = "${var.prefix}-rds-proxy-reader"
  vpc_subnet_ids         = var.db_subnet_ids
  vpc_security_group_ids = [aws_security_group.proxy.id]
  target_role            = "READ_ONLY" # Reader インスタンスにルーティング
}

# ─── SSM Parameter Store にエンドポイントを保存 ───────────────
# アプリはハードコードではなく SSM から取得する
resource "aws_ssm_parameter" "proxy_endpoint" {
  name  = "/arpl/rds-proxy/endpoint"
  type  = "String"
  value = aws_db_proxy.main.endpoint
}

resource "aws_ssm_parameter" "proxy_reader_endpoint" {
  name  = "/arpl/rds-proxy/reader-endpoint"
  type  = "String"
  value = aws_db_proxy_endpoint.reader.endpoint
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/arpl/rds/db-name"
  type  = "String"
  value = "appdb"
}
