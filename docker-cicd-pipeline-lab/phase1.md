# ✅Phase 1 — ネットワーク基盤 + ECR

## このフェーズのゴール

VPC・サブネット・セキュリティグループ・VPC Endpoint・ECR リポジトリを Terraform で構築する。
NAT Gateway を使わず、VPC Endpoint 経由で ECS → ECR/S3 の通信を実現することがポイント。

---

## 作成するファイル

### `terraform/versions.tf`

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "docker-cicd-pipeline-lab"
    }
  }
}
```

### `terraform/variables.tf`

```hcl
variable "aws_region" {
  description = "デプロイ先 AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "プロジェクト名 (リソース命名に使用)"
  type        = string
  default     = "cicd-lab"
}

variable "environment" {
  description = "環境名"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "VPC の CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "使用するアベイラビリティゾーン"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}
```

### `terraform/main.tf`

```hcl
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  account_id   = data.aws_caller_identity.current.account_id
}

module "networking" {
  source = "./modules/networking"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  account_id         = local.account_id
  aws_region         = var.aws_region
}

module "ecr" {
  source = "./modules/ecr"

  name_prefix = local.name_prefix
  account_id  = local.account_id
}
```

### `terraform/outputs.tf`

```hcl
output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID リスト"
  value       = module.networking.public_subnet_ids
}

output "ecr_repository_url" {
  description = "ECR リポジトリ URL"
  value       = module.ecr.repository_url
}
```

### `terraform/modules/networking/main.tf`

```hcl
# VPC
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # VPC Endpoint の DNS 解決に必要なため有効化
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

# パブリックサブネット (ALB 配置用)
resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = var.availability_zones[count.index]

  # ALB は EIP 不要なため map_public_ip は false
  map_public_ip_on_launch = false

  tags = { Name = "${var.name_prefix}-public-${count.index + 1}" }
}

# プライベートサブネット (ECS タスク配置用)
resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.name_prefix}-private-${count.index + 1}" }
}

# Internet Gateway (ALB のインターネット疎通に必要)
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# パブリックルートテーブル
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# プライベートルートテーブル (NAT Gateway なし — VPC Endpoint で代替)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-rt-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ─── VPC Endpoints ───────────────────────────────────────────────

# S3 Gateway Endpoint (無料 — ECR イメージレイヤー取得に必要)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name_prefix}-vpce-s3" }
}

# ECR API Interface Endpoint (イメージ manifest 取得)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-ecr-api" }
}

# ECR Docker Interface Endpoint (イメージレイヤー取得)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-ecr-dkr" }
}

# CloudWatch Logs Interface Endpoint (ECS タスクログ送信)
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-logs" }
}

# ─── Security Groups ─────────────────────────────────────────────

# VPC Endpoint 用 SG (プライベートサブネットからの HTTPS のみ許可)
resource "aws_security_group" "vpce" {
  name        = "${var.name_prefix}-sg-vpce"
  description = "VPC Endpoint 用 — プライベートサブネットから HTTPS のみ"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg-vpce" }
}

# ALB 用 SG
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-sg-alb"
  description = "ALB 用 — インターネットから HTTP のみ受け入れ"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg-alb" }
}

# ECS タスク用 SG (ALB からのみ受け入れ)
resource "aws_security_group" "ecs_task" {
  name        = "${var.name_prefix}-sg-ecs-task"
  description = "ECS タスク用 — ALB SG からの 8080 のみ許可"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg-ecs-task" }
}
```

### `terraform/modules/networking/variables.tf`

```hcl
variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "availability_zones" { type = list(string) }
variable "account_id" { type = string }
variable "aws_region" { type = string }
```

### `terraform/modules/networking/outputs.tf`

```hcl
output "vpc_id"              { value = aws_vpc.main.id }
output "public_subnet_ids"   { value = aws_subnet.public[*].id }
output "private_subnet_ids"  { value = aws_subnet.private[*].id }
output "sg_alb_id"           { value = aws_security_group.alb.id }
output "sg_ecs_task_id"      { value = aws_security_group.ecs_task.id }
```

### `terraform/modules/ecr/main.tf`

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "${var.name_prefix}-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # push 時に自動スキャンを実行し、脆弱性を早期検知
    scan_on_push = true
  }

  tags = { Name = "${var.name_prefix}-app" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "最新10イメージのみ保持 — ストレージコスト削減"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

### `terraform/modules/ecr/variables.tf`

```hcl
variable "name_prefix" { type = string }
variable "account_id"  { type = string }
```

### `terraform/modules/ecr/outputs.tf`

```hcl
output "repository_url"  { value = aws_ecr_repository.app.repository_url }
output "repository_name" { value = aws_ecr_repository.app.name }
output "repository_arn"  { value = aws_ecr_repository.app.arn }
```

### `terraform/terraform.tfvars.example`

```hcl
aws_region   = "ap-northeast-1"
project_name = "cicd-lab"
environment  = "prod"
```

---

## アプリケーション (ダミー確認用)

### `app/Dockerfile`

```dockerfile
# --- ビルドステージ ---
# マルチステージビルドでイメージサイズを最小化
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# --- 実行ステージ ---
FROM python:3.12-slim

# セキュリティ: root 以外のユーザーで実行
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app
COPY --from=builder /root/.local /home/appuser/.local
COPY app.py .

USER appuser
ENV PATH=/home/appuser/.local/bin:$PATH

EXPOSE 8080
CMD ["python", "app.py"]
```

### `app/app.py`

```python
"""
シンプルな HTTP サーバー — ECS Fargate 動作確認用
デプロイされたコミット SHA を返すことで CD が正しく動いたか確認できる
"""
import os
import http.server
import json
from datetime import datetime, timezone

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({"status": "healthy"}).encode()
            self.send_response(200)
        else:
            body = json.dumps({
                "message": "Hello from ECS Fargate!",
                "image_tag": os.environ.get("IMAGE_TAG", "unknown"),
                "hostname": os.environ.get("HOSTNAME", "unknown"),
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }).encode()
            self.send_response(200)

        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[{datetime.now(timezone.utc).isoformat()}] {format % args}")

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    server = http.server.HTTPServer(("", port), Handler)
    print(f"Server starting on port {port}")
    server.serve_forever()
```

### `app/requirements.txt`

```
# 標準ライブラリのみ使用するため依存なし
# (Dockerfile の COPY ステップを統一するためファイルは残す)
```

### `app/.dockerignore`

```
__pycache__/
*.pyc
*.pyo
.env
.git
.gitignore
README.md
```

---

## 実行手順

```bash
# 1. tfvars を作成
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# 2. フォーマット & バリデーション
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate

# 3. プラン確認
terraform -chdir=terraform init
terraform -chdir=terraform plan

# 4. 適用
terraform -chdir=terraform apply -auto-approve

# 5. Docker ローカル動作確認
docker build -t cicd-lab-app:local ./app
docker run --rm -p 8080:8080 cicd-lab-app:local
curl http://localhost:8080/health
curl http://localhost:8080/
```

---

## 完了チェックリスト

- [ ] `terraform apply` がエラーなく完了した
- [ ] VPC・サブネット (public×2, private×2) が AWS コンソールで確認できる
- [ ] VPC Endpoint (S3, ECR API, ECR DKR, Logs) が4つ作成されている
- [ ] ECR リポジトリ `cicd-lab-prod-app` が作成されている
- [ ] Docker ローカルビルドが成功し `/health` が `200` を返す
- [ ] `terraform fmt` で差分が出ない

## 口頭説明チェックポイント

> 以下を見ずに 3 分間で説明できるか確認すること

1. **なぜ NAT Gateway を使わないのか？** — VPC Endpoint との違いとコスト差は？
2. **ECR への通信に必要な VPC Endpoint が2つある理由は？** — API と DKR の役割の違いは？
3. **S3 Gateway Endpoint が無料な理由と、Interface Endpoint との違いは？**
4. **ECS タスクの SG で ALB の SG を参照している理由は？** — CIDR で書いた場合の問題点は？