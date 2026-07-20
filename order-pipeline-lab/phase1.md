# Phase 1: 基盤インフラ構築

## 目標
VPC (VPC Endpoint構成)、SQS + DLQ、DynamoDB、IAM を Terraform で構築する。
NAT Gateway なしで Lambda/ECS が AWS サービスと通信できる VPC Endpoint 構成を理解する。

## 作成するリソース

### ディレクトリ構成
```
terraform/
├── main.tf
├── variables.tf
├── outputs.tf
├── locals.tf
└── modules/
    ├── networking/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── sqs/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## Task 1: terraform/ ルートファイル

### `terraform/locals.tf`
```hcl
locals {
  project     = "order-pipeline"
  environment = "dev"
  region      = "ap-northeast-1"

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}
```

### `terraform/variables.tf`
```hcl
variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネット CIDR リスト (2AZ分)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}
```

### `terraform/main.tf`
```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "networking" {
  source = "./modules/networking"

  project              = local.project
  environment          = local.environment
  vpc_cidr             = var.vpc_cidr
  private_subnet_cidrs = var.private_subnet_cidrs
  common_tags          = local.common_tags
}

module "sqs" {
  source = "./modules/sqs"

  project     = local.project
  environment = local.environment
  common_tags = local.common_tags
}

# DynamoDB: 注文ステータス管理テーブル
resource "aws_dynamodb_table" "orders" {
  name         = "${local.project}-orders"
  billing_mode = "PAY_PER_REQUEST" # なぜ: 負荷が不定のためオンデマンド課金を選択
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = "status-created_at-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  # なぜ: 本番移行時のデータ保護。dev環境でも習慣として有効化
  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.project}-orders"
  })
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

output "orders_queue_url" {
  description = "注文キュー URL"
  value       = module.sqs.orders_queue_url
}

output "orders_queue_arn" {
  description = "注文キュー ARN"
  value       = module.sqs.orders_queue_arn
}

output "orders_dlq_arn" {
  description = "注文 DLQ ARN"
  value       = module.sqs.orders_dlq_arn
}

output "dynamodb_table_name" {
  description = "DynamoDB テーブル名"
  value       = aws_dynamodb_table.orders.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB テーブル ARN"
  value       = aws_dynamodb_table.orders.arn
}
```

---

## Task 2: networking モジュール

### `terraform/modules/networking/variables.tf`
```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_cidrs" { type = list(string) }
variable "common_tags" { type = map(string) }
```

### `terraform/modules/networking/main.tf`
以下をすべて実装すること:

```hcl
# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # なぜ: VPC Endpoint の DNS 解決に必須
  enable_dns_support   = true

  tags = merge(var.common_tags, { Name = "${var.project}-vpc" })
}

# プライベートサブネット (2AZ)
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # なぜ: Lambda/ECS はプライベートサブネットに配置し、
  #       パブリック IP を持たせない設計
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${var.project}-private-${count.index + 1}"
  })
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ルートテーブル (プライベート用)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  # なぜ: NAT Gateway を使わないため、デフォルトルートなし
  #       インターネット通信は VPC Endpoint 経由のみ許可
  tags = merge(var.common_tags, { Name = "${var.project}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# セキュリティグループ: VPC Endpoint 用
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project}-vpc-endpoints-sg"
  description = "VPC Endpoint へのアクセスを許可"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # なぜ: VPC 内部からのみ HTTPS アクセスを許可
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, { Name = "${var.project}-vpc-endpoints-sg" })
}

# VPC Endpoint: SQS (Interface)
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true # なぜ: 既存コードの endpoint URL を変更せずに利用可能

  tags = merge(var.common_tags, { Name = "${var.project}-sqs-endpoint" })
}

# VPC Endpoint: DynamoDB (Gateway) ← 無料
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.common_tags, { Name = "${var.project}-dynamodb-endpoint" })
}

# VPC Endpoint: ECR API (Interface) ← ECS Fargate が ECR から pull するために必要
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-ecr-api-endpoint" })
}

# VPC Endpoint: ECR DKR (Interface) ← Docker イメージ layer の pull に必要
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-ecr-dkr-endpoint" })
}

# VPC Endpoint: CloudWatch Logs (Interface) ← ECS/Lambda のログ送信
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-logs-endpoint" })
}

# VPC Endpoint: SSM (Interface) ← Parameter Store 参照
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-ssm-endpoint" })
}

# VPC Endpoint: Step Functions (Interface)
resource "aws_vpc_endpoint" "states" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.states"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-states-endpoint" })
}

# VPC Endpoint: X-Ray (Interface) ← トレーシング
resource "aws_vpc_endpoint" "xray" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.xray"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, { Name = "${var.project}-xray-endpoint" })
}

# S3 Gateway Endpoint ← ECR の layer データは S3 から取得される
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.common_tags, { Name = "${var.project}-s3-endpoint" })
}
```

### `terraform/modules/networking/outputs.tf`
```hcl
output "vpc_id" { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "vpc_endpoints_sg_id" { value = aws_security_group.vpc_endpoints.id }
```

---

## Task 3: SQS モジュール

### `terraform/modules/sqs/variables.tf`
```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "common_tags" { type = map(string) }
```

### `terraform/modules/sqs/main.tf`
```hcl
# DLQ (Dead Letter Queue) — 先に作成する
resource "aws_sqs_queue" "orders_dlq" {
  name = "${var.project}-orders-dlq"

  # なぜ: DLQ は調査・再処理の猶予として 7日間保持
  message_retention_seconds = 604800

  tags = merge(var.common_tags, { Name = "${var.project}-orders-dlq" })
}

# メインの注文キュー
resource "aws_sqs_queue" "orders" {
  name = "${var.project}-orders-queue"

  # なぜ: Step Functions の最大実行時間 (1年) より長くする必要はないが、
  #       1回の処理で最大 5分かかる想定で 300秒に設定
  #       visibility_timeout < 処理時間 だとメッセージが再配信されてしまう
  visibility_timeout_seconds = 300

  # なぜ: 処理失敗したメッセージを調査できるよう 1日保持
  message_retention_seconds = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    # なぜ: 3回受信して失敗したメッセージは DLQ へ移動
    #       1回目: 一時的な障害かもしれない
    #       2回目: まだリトライする価値がある
    #       3回目: 諦めて DLQ で原因調査
    maxReceiveCount = 3
  })

  tags = merge(var.common_tags, { Name = "${var.project}-orders-queue" })
}

# CloudWatch Alarm: DLQ メッセージ数監視
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.project}-dlq-messages-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0 # なぜ: DLQ に 1件でも届いたらアラート

  dimensions = {
    QueueName = aws_sqs_queue.orders_dlq.name
  }

  alarm_description = "DLQ にメッセージが届いています。注文処理の失敗を調査してください。"

  tags = var.common_tags
}
```

### `terraform/modules/sqs/outputs.tf`
```hcl
output "orders_queue_url" { value = aws_sqs_queue.orders.url }
output "orders_queue_arn" { value = aws_sqs_queue.orders.arn }
output "orders_queue_name" { value = aws_sqs_queue.orders.name }
output "orders_dlq_arn" { value = aws_sqs_queue.orders_dlq.arn }
output "orders_dlq_url" { value = aws_sqs_queue.orders_dlq.url }
output "dlq_alarm_arn" { value = aws_cloudwatch_metric_alarm.dlq_messages.arn }
```

---

## Task 4: ADR 作成

### `docs/adr/adr-001-sqs-visibility-timeout.md`
以下の構成で作成すること (内容は自分の言葉で記述):

```markdown
# ADR-001: SQS visibility_timeout_seconds の設定値

## Status
Accepted

## Context
[なぜこの設定が必要か、背景を書く]

## Decision
visibility_timeout_seconds = 300 に設定する

## Consequences
[この設定にすることで何が起きるか、トレードオフを書く]
```

---

## 実行手順

```bash
cd terraform

# 初期化
terraform init

# 差分確認 (VPC Endpoint が 9個あることを確認)
terraform plan

# 適用
terraform apply -auto-approve

# 出力確認
terraform output
```

---

## 動作確認

```bash
# SQS にテストメッセージを送信
aws sqs send-message \
  --queue-url $(terraform output -raw orders_queue_url) \
  --message-body '{"order_id": "test-001", "amount": 1000}' \
  --region ap-northeast-1

# メッセージ数確認
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw orders_queue_url) \
  --attribute-names ApproximateNumberOfMessages \
  --region ap-northeast-1

# DynamoDB テーブル確認
aws dynamodb describe-table \
  --table-name order-pipeline-orders \
  --region ap-northeast-1 | jq '.Table.TableStatus'
```

---

## フェーズ完了チェックリスト

- [ ] `terraform apply` がエラーなく完了
- [ ] `terraform output` で VPC ID / SQS URL / DynamoDB ARN が表示される
- [ ] SQS にテストメッセージを送信できる
- [ ] VPC Endpoint が 9個作成されている (`aws ec2 describe-vpc-endpoints`)
- [ ] DLQ の CloudWatch Alarm が存在する
- [ ] ADR-001 を自分の言葉で記述した

## 口頭説明チェック
「なぜ NAT Gateway を使わずに VPC Endpoint を使うのか」を 3分で説明できるか？
「visibility_timeout と maxReceiveCount の関係」を説明できるか？