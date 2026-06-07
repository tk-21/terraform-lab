# ✅Phase 1 — 基盤構築（VPC・Terraform State・VPC Endpoint）

## このフェーズのゴール

- Terraform remote state 用 S3 バケット + DynamoDB ロックテーブルを作成
- Aurora / RDS Proxy / ECS が稼働する VPC・サブネット構成を構築
- NAT Gateway を使わず、必要な AWS サービスへは VPC Endpoint のみで到達できることを確認

## 前提条件チェック

```bash
aws --version          # AWS CLI v2
terraform --version    # v1.7 以上
aws sts get-caller-identity  # 認証確認
```

---

## Step 1-1: ディレクトリ作成

```bash
mkdir -p aurora-rds-proxy-lab/{terraform/{bootstrap,modules/{networking,aurora,rds-proxy,secrets,ecs-app},environments/dev},app/{db,api},lambda/notifier,scripts,docs/{adr,runbook},.github/workflows}
cd aurora-rds-proxy-lab
```

---

## Step 1-2: Terraform Bootstrap（State バックエンド）

### `terraform/bootstrap/main.tf`

```hcl
# Terraform State 管理用リソース
# ローカル State で bootstrap 自体を管理する（鶏卵問題を避けるため）
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "aurora-rds-proxy-lab"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

variable "aws_region" {
  default = "ap-northeast-1"
}

variable "prefix" {
  default = "arpl"
}

# Terraform State 保存用 S3 バケット
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.prefix}-tfstate-${data.aws_caller_identity.current.account_id}"

  # 誤削除防止
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# パブリックアクセス完全ブロック
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State ロック用 DynamoDB テーブル
resource "aws_dynamodb_table" "tflock" {
  name         = "${var.prefix}-tflock"
  billing_mode = "PAY_PER_REQUEST" # コスト最適化: プロビジョンド不要
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

data "aws_caller_identity" "current" {}

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "tflock_table" {
  value = aws_dynamodb_table.tflock.name
}
```

### Bootstrap 実行

```bash
cd terraform/bootstrap
terraform init
terraform apply -auto-approve
# 出力された tfstate_bucket 名をメモする
cd ../..
```

---

## Step 1-3: Networking モジュール

### `terraform/modules/networking/main.tf`

```hcl
# =============================================================
# VPC・サブネット・セキュリティグループ・VPC Endpoint 定義
# NAT Gateway は一切使用しない（コスト削減 + セキュリティ方針）
# Private Subnet からの AWS API アクセスは全て VPC Endpoint 経由
# =============================================================

variable "prefix" {}
variable "vpc_cidr" { default = "10.0.0.0/16" }
variable "aws_region" { default = "ap-northeast-1" }

locals {
  # 使用する AZ（ap-northeast-1a / 1c の2系統）
  azs = ["${var.aws_region}a", "${var.aws_region}c"]

  # サブネット CIDR 設計
  # Private App Subnet: ECS Fargate タスク配置用
  # Private DB Subnet:  Aurora / RDS Proxy 配置用（アプリ層と分離）
  # Public Subnet:      ALB のみ（EC2/NAT Gateway は置かない）
  public_cidrs      = ["10.0.0.0/24", "10.0.1.0/24"]
  private_app_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
  private_db_cidrs  = ["10.0.20.0/24", "10.0.21.0/24"]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true   # VPC Endpoint の名前解決に必須
  enable_dns_hostnames = true   # RDS エンドポイントの DNS 解決に必須
}

# ─── Public Subnet（ALB 用）───────────────────────────────────
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false # 不要なパブリック IP 割り当てを抑制
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ─── Private App Subnet（ECS Fargate）────────────────────────
resource "aws_subnet" "private_app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_app_cidrs[count.index]
  availability_zone = local.azs[count.index]
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id
  # デフォルトルートなし = インターネット到達不可
  # AWS API へは VPC Endpoint のみで接続
}

resource "aws_route_table_association" "private_app" {
  count          = 2
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app.id
}

# ─── Private DB Subnet（Aurora / RDS Proxy）──────────────────
resource "aws_subnet" "private_db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_db_cidrs[count.index]
  availability_zone = local.azs[count.index]
}

resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id
  # DB 層は外部通信完全遮断
}

resource "aws_route_table_association" "private_db" {
  count          = 2
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db.id
}

# ─── VPC Endpoint 用セキュリティグループ ─────────────────────
resource "aws_security_group" "vpc_endpoint" {
  name   = "${var.prefix}-vpce-sg"
  vpc_id = aws_vpc.main.id

  # VPC 内部からの HTTPS のみ許可（VPC Endpoint は 443 ポートで通信）
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "VPC内部からのHTTPS（VPC Endpoint通信用）"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── VPC Endpoints ────────────────────────────────────────────
# Interface Endpoint（Private DNS 有効）
locals {
  interface_endpoints = [
    "secretsmanager",   # Secrets Manager（ローテーション Lambda 含む）
    "ecr.api",          # ECR API（イメージメタデータ）
    "ecr.dkr",          # ECR Docker Registry（イメージ pull）
    "logs",             # CloudWatch Logs
    "ssm",              # SSM Parameter Store
    "rds",              # RDS API（フェイルオーバー API 呼び出し用）
    "monitoring",       # CloudWatch メトリクス
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true # エンドポイント DNS を自動的に向けてくれる

  subnet_ids = aws_subnet.private_app[*].id
  security_group_ids = [aws_security_group.vpc_endpoint.id]
}

# S3 は Gateway Endpoint（無料 + 高帯域）
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [
    aws_route_table.private_app.id,
    aws_route_table.private_db.id,
  ]
}

# ─── Outputs ─────────────────────────────────────────────────
output "vpc_id"              { value = aws_vpc.main.id }
output "public_subnet_ids"   { value = aws_subnet.public[*].id }
output "private_app_subnet_ids" { value = aws_subnet.private_app[*].id }
output "private_db_subnet_ids"  { value = aws_subnet.private_db[*].id }
output "vpc_endpoint_sg_id"  { value = aws_security_group.vpc_endpoint.id }
output "vpc_cidr"            { value = aws_vpc.main.cidr_block }
```

---

## Step 1-4: environments/dev バックエンド設定

### `terraform/environments/dev/backend.tf`

```hcl
terraform {
  required_version = ">= 1.7"

  backend "s3" {
    # bootstrap で出力された bucket 名に書き換える
    bucket         = "arpl-tfstate-XXXXXXXXXXXX"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "arpl-tflock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "aurora-rds-proxy-lab"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
```

### `terraform/environments/dev/variables.tf`

```hcl
variable "aws_region"      { default = "ap-northeast-1" }
variable "prefix"          { default = "arpl" }
variable "chatwork_room_id" {
  description = "Chatwork通知先ルームID（機密値のため tfvars に書かない）"
  type        = string
}
```

### `terraform/environments/dev/terraform.tfvars`

```hcl
# 機密値は書かない
aws_region = "ap-northeast-1"
prefix     = "arpl"
# chatwork_room_id は環境変数 TF_VAR_chatwork_room_id で渡す
```

### `terraform/environments/dev/main.tf`（Phase 1 時点）

```hcl
module "networking" {
  source     = "../../modules/networking"
  prefix     = var.prefix
  aws_region = var.aws_region
}
```

---

## Step 1-5: 実行・検証

```bash
cd terraform/environments/dev

# backend.tf の bucket 名を bootstrap 出力値に書き換えてから実行
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

### VPC Endpoint 疎通確認

```bash
# ECS タスクが起動する Private Subnet から疎通確認するために
# 一時的に SSM Session Manager 対応の EC2（arm64）を起動して確認する

# Secrets Manager Endpoint への到達確認
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'VpcEndpoints[].{Service:ServiceName,State:State}' \
  --output table

# 全 Endpoint が "available" であることを確認
```

---

## Step 1-6: ADR 雛形作成

以下ファイルを作成し、**Decision・Consequences は自分の言葉で記述** すること。

### `docs/adr/001-aurora-serverless-v2.md`

```markdown
# ADR 001: Aurora Serverless v2 を採用する

## Status
Accepted

## Context
...（AI生成可）

## Decision
<!-- ここは自分の言葉で書く。なぜ Provisioned ではなく Serverless v2 なのか -->

## Consequences
<!-- ここは自分の言葉で書く。ACU の最小値設定・コールドスタート・コスト予測 -->
```

### `docs/adr/004-vpc-endpoint-only.md`

```markdown
# ADR 004: NAT Gateway を廃止し VPC Endpoint のみを使用する

## Status
Accepted

## Context
...

## Decision
<!-- NAT Gateway との比較をした上での判断を自分の言葉で -->

## Consequences
<!-- コスト・セキュリティ・運用上のトレードオフを自分の言葉で -->
```

---

## フェーズ完了チェック

- [ ] S3 バケット・DynamoDB テーブルが作成されている
- [ ] VPC (10.0.0.0/16) と 6 サブネット（Public×2, App×2, DB×2）が存在する
- [ ] VPC Endpoint 7本が `available` 状態
- [ ] `terraform validate` がエラーなし
- [ ] `terraform fmt` 適用済み
- [ ] ADR 001・004 の Decision/Consequences を自分の言葉で記述した

## 口頭説明チェック（Phase 1）

以下を5分で説明できること:

1. なぜ NAT Gateway を使わないのか（コスト・セキュリティ両面）
2. Gateway Endpoint と Interface Endpoint の違い
3. `enable_dns_support = true` が VPC Endpoint に必要な理由