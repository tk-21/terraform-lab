# ✅Phase 3 — RDS Proxy + IAM 認証

## 前フェーズ確認

```bash
cd terraform/environments/dev
terraform output aurora_cluster_endpoint  # エンドポイントが出力されること
```

## このフェーズのゴール

- RDS Proxy を Aurora クラスターの前段に配置し接続プールを有効化
- ECS タスクが **ユーザー名/パスワードを持たずに** IAM 認証トークンで接続できる構成にする
- Writer Proxy / Reader Proxy の 2 エンドポイントを確認する

---

## Step 3-1: RDS Proxy モジュール

### `terraform/modules/rds-proxy/variables.tf`

```hcl
variable "prefix"             {}
variable "vpc_id"             {}
variable "db_subnet_ids"      { type = list(string) }
variable "aurora_sg_id"       {}
variable "cluster_id"         {}
variable "cluster_endpoint"   {}
variable "reader_endpoint"    {}
variable "master_secret_arn"  {}
variable "db_master_username" {}
variable "aws_region"         { default = "ap-northeast-1" }
variable "aws_account_id"     {}
```

### `terraform/modules/rds-proxy/main.tf`

```hcl
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
        Sid      = "DecryptSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*" # Secrets Manager のデフォルト KMS キー
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
    max_idle_connections_percent = 50  # idle 接続は 50% まで保持
  }
}

resource "aws_db_proxy_target" "aurora" {
  db_proxy_name          = aws_db_proxy.main.name
  target_group_name      = aws_db_proxy_default_target_group.main.name
  db_cluster_identifier  = var.cluster_id
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

# ─── Outputs ─────────────────────────────────────────────────
output "proxy_endpoint"        { value = aws_db_proxy.main.endpoint }
output "proxy_reader_endpoint" { value = aws_db_proxy_endpoint.reader.endpoint }
output "proxy_sg_id"           { value = aws_security_group.proxy.id }
output "proxy_arn"             { value = aws_db_proxy.main.arn }
```

### `terraform/modules/rds-proxy/iam_app.tf`

```hcl
# ─── ECS タスクが Proxy に接続するための IAM ポリシー ─────────
# このポリシーは Phase 5 の ECS モジュールの Task Role にアタッチする

resource "aws_iam_policy" "app_rds_connect" {
  name        = "${var.prefix}-app-rds-connect-policy"
  description = "ECS Fargateタスクが RDS Proxy に IAM 認証で接続するための最小権限ポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RDSProxyConnect"
        Effect = "Allow"
        Action = ["rds-db:connect"]
        # リソース形式: arn:aws:rds-db:{region}:{account}:dbuser:{proxy-resource-id}/{db-user}
        Resource = [
          "arn:aws:rds-db:${var.aws_region}:${var.aws_account_id}:dbuser:${aws_db_proxy.main.arn}/*"
        ]
      }
    ]
  })
}

output "app_rds_connect_policy_arn" {
  value = aws_iam_policy.app_rds_connect.arn
}
```

---

## Step 3-2: environments/dev/main.tf に追記

```hcl
data "aws_caller_identity" "current" {}

module "rds_proxy" {
  source = "../../modules/rds-proxy"

  prefix             = var.prefix
  vpc_id             = module.networking.vpc_id
  db_subnet_ids      = module.networking.private_db_subnet_ids
  aurora_sg_id       = module.aurora.aurora_sg_id
  cluster_id         = module.aurora.cluster_id
  cluster_endpoint   = module.aurora.cluster_endpoint
  reader_endpoint    = module.aurora.cluster_reader_endpoint
  master_secret_arn  = module.aurora.master_secret_arn
  db_master_username = module.aurora.db_master_username
  aws_region         = var.aws_region
  aws_account_id     = data.aws_caller_identity.current.account_id
}

output "proxy_endpoint" {
  value = module.rds_proxy.proxy_endpoint
}
output "proxy_reader_endpoint" {
  value = module.rds_proxy.proxy_reader_endpoint
}
```

---

## Step 3-3: 実行・検証

```bash
cd terraform/environments/dev
terraform fmt -recursive
terraform validate
terraform plan
terraform apply  # Proxy 作成に 5 分程度かかる

# Proxy 状態確認
aws rds describe-db-proxies \
  --db-proxy-name arpl-rds-proxy \
  --query 'DBProxies[0].{Status:Status,Endpoint:Endpoint,RequireTLS:RequireTLS}' \
  --output json

# Target Group の状態確認（"available" になるまで待つ）
aws rds describe-db-proxy-targets \
  --db-proxy-name arpl-rds-proxy \
  --query 'Targets[*].{Endpoint:Endpoint,Port:Port,State:TargetHealth.State}' \
  --output table
```

### IAM 認証トークン生成テスト

```bash
# Proxy への IAM 認証トークン生成確認
PROXY_ENDPOINT=$(aws ssm get-parameter --name /arpl/rds-proxy/endpoint --query Parameter.Value --output text)

aws rds generate-db-auth-token \
  --hostname $PROXY_ENDPOINT \
  --port 5432 \
  --region ap-northeast-1 \
  --username dbadmin

# 出力されたトークン（長い文字列）が認証トークン
# 有効期限: 15 分
```

---

## Step 3-4: ADR 記述

### `docs/adr/002-rds-proxy-iam-auth.md` を完成させる

```markdown
# ADR 002: RDS Proxy を採用し IAM 認証を必須にする

## Status
Accepted

## Context
ECS Fargate の場合、タスクが起動・停止するたびに DB 接続が新規作成・切断される。
Aurora の max_connections はインスタンスメモリに依存し、Serverless v2 の最小 ACU では低い。

## Decision
<!-- 自分の言葉で: なぜ RDS Proxy を挟むのか（接続プール目的） -->
<!-- なぜ IAM 認証を必須にするのか（パスワード管理排除） -->
<!-- require_tls = true にした理由 -->

## Consequences
<!-- Proxy 自体のコスト（~$0.015/hr）は許容するか -->
<!-- Proxy が SPoF にならないか（実はマネージドで Multi-AZ） -->
<!-- IAM 認証トークンの 15 分有効期限をどう扱うか -->
```

---

## フェーズ完了チェック

- [ ] RDS Proxy が `available` 状態
- [ ] Target が Writer/Reader 両方 `available`
- [ ] Reader Endpoint が作成されている
- [ ] SSM Parameter Store に 3 パラメータ保存済み
- [ ] IAM 認証トークンが生成できる
- [ ] `terraform fmt` / `terraform validate` 適用済み
- [ ] ADR 002 を自分の言葉で記述

## 口頭説明チェック（Phase 3）

以下を5分で説明できること:

1. RDS Proxy の接続プールの仕組み（なぜ Aurora の接続数を節約できるのか）
2. IAM 認証フロー（ECS タスク → Proxy まで）
3. `rds-db:connect` アクションのリソース ARN 形式の意味