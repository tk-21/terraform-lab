# ✅Phase 1 — Terraform基盤構築

## 目標
VPC Endpoints / S3 / DynamoDB / ECR / IAM を Terraform で構築する。
NAT Gateway を一切使わずに ECS・Lambda がAWSサービスへ通信できる構成を実現する。

---

## タスク一覧

### 1-1. environments/dev の骨格ファイル作成

`terraform/environments/dev/main.tf` を作成する。

```hcl
# terraform/environments/dev/main.tf

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # ハンズオン用途のためlocalステートを使用
  # 本番移行時はS3+DynamoDBに切り替える
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Project   = "ai-inference-pipeline"
    Env       = var.env
    ManagedBy = "terraform"
  }
  name_prefix = "aip-${var.env}"
}
```

`terraform/environments/dev/variables.tf` を作成する。

```hcl
variable "aws_region" {
  description = "デプロイ先AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "env" {
  description = "環境名（dev/stg/prod）"
  type        = string
  default     = "dev"
}

variable "aws_account_id" {
  description = "AWSアカウントID（S3バケット名の一意性確保に使用）"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID（既存VPCを利用する場合）"
  type        = string
}

variable "private_subnet_ids" {
  description = "ECS/Lambda用プライベートサブネットIDリスト"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック（VPC Endpointのセキュリティグループに使用）"
  type        = string
  default     = "10.0.0.0/16"
}

variable "chatwork_room_id" {
  description = "Chatwork通知先ルームID"
  type        = string
}
```

`terraform/environments/dev/terraform.tfvars` を作成する（機密情報は含めない）。

```hcl
aws_region       = "ap-northeast-1"
env              = "dev"
aws_account_id   = "YOUR_ACCOUNT_ID"   # 要書き換え
vpc_id           = "YOUR_VPC_ID"        # 要書き換え
private_subnet_ids = ["YOUR_SUBNET_1", "YOUR_SUBNET_2"]  # 要書き換え
vpc_cidr         = "10.0.0.0/16"
chatwork_room_id = "YOUR_ROOM_ID"       # 要書き換え
```

---

### 1-2. S3モジュール作成

`terraform/modules/s3/main.tf`:

```hcl
# 推論パイプラインの入力データ受け口
# EventBridgeトリガーのソースになるため、バケット通知を有効化
resource "aws_s3_bucket" "input" {
  bucket = "${var.name_prefix}-input-${var.account_id}"
  # 誤削除防止のため本番では force_destroy = false にする
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "input" {
  bucket = aws_s3_bucket.input.id
  # 推論入力データはパブリックアクセス不要
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "output" {
  bucket        = "${var.name_prefix}-output-${var.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "output" {
  bucket                  = aws_s3_bucket.output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

`terraform/modules/s3/variables.tf`:

```hcl
variable "name_prefix" { type = string }
variable "account_id"  { type = string }
```

`terraform/modules/s3/outputs.tf`:

```hcl
output "input_bucket_name" { value = aws_s3_bucket.input.bucket }
output "input_bucket_arn"  { value = aws_s3_bucket.input.arn }
output "output_bucket_name" { value = aws_s3_bucket.output.bucket }
output "output_bucket_arn"  { value = aws_s3_bucket.output.arn }
```

---

### 1-3. DynamoDBモジュール作成

`terraform/modules/dynamodb/main.tf`:

```hcl
# 推論結果の永続化先
# GSIでステータス別に絞り込みできるようにする（運用時のデバッグ効率向上のため）
resource "aws_dynamodb_table" "results" {
  name         = "${var.name_prefix}-results"
  billing_mode = "PAY_PER_REQUEST"  # ハンズオンでアクセスが読めないためオンデマンド
  hash_key     = "job_id"
  range_key    = "created_at"

  attribute {
    name = "job_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  # ステータス別検索を可能にするGSI
  # 「失敗したジョブだけ一覧表示」等の運用クエリを想定
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
```

`terraform/modules/dynamodb/variables.tf`:

```hcl
variable "name_prefix" { type = string }
```

`terraform/modules/dynamodb/outputs.tf`:

```hcl
output "table_name" { value = aws_dynamodb_table.results.name }
output "table_arn"  { value = aws_dynamodb_table.results.arn }
```

---

### 1-4. ECRモジュール作成

`terraform/modules/ecr/main.tf`:

```hcl
# Docker前処理コンテナのイメージリポジトリ
resource "aws_ecr_repository" "preprocessor" {
  name                 = "aip/${var.env}/preprocessor"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # プッシュ時に脆弱性スキャンを自動実行（無料範囲内）
    scan_on_push = true
  }
}

# 古いイメージを自動削除してECRストレージコストを抑制
resource "aws_ecr_lifecycle_policy" "preprocessor" {
  repository = aws_ecr_repository.preprocessor.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新3世代のみ保持"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}
```

`terraform/modules/ecr/variables.tf`:

```hcl
variable "env"         { type = string }
variable "name_prefix" { type = string }
```

`terraform/modules/ecr/outputs.tf`:

```hcl
output "repository_url"  { value = aws_ecr_repository.preprocessor.repository_url }
output "repository_name" { value = aws_ecr_repository.preprocessor.name }
```

---

### 1-5. VPC Endpointセキュリティグループ + Endpointモジュール作成

`terraform/modules/vpc_endpoints/main.tf`:

```hcl
# NAT Gatewayを使わずにAWSサービスへプライベート通信するためのVPC Endpoint群
# Interface型はENIを作成するためセキュリティグループが必要

resource "aws_security_group" "vpce" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "VPC Endpoint用 - VPC内からのHTTPS通信のみ許可"
  vpc_id      = var.vpc_id

  ingress {
    description = "VPC内からのHTTPS"
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
}

# S3はGateway型（無料）
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
}

# 以下はInterface型（ENI経由）
locals {
  interface_services = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "ssm",
    "sts",
    "bedrock-runtime",
    "states",         # Step Functions
    "ecs",
    "ecs-agent",
    "ecs-telemetry",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_services)

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpce.id]
  # プライベートDNSを有効化することでSDKの向き先を自動的に変更
  private_dns_enabled = true
}

# DynamoDBはGateway型（無料）
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
}
```

`terraform/modules/vpc_endpoints/variables.tf`:

```hcl
variable "name_prefix"        { type = string }
variable "vpc_id"             { type = string }
variable "vpc_cidr"           { type = string }
variable "region"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "route_table_ids"    { type = list(string) }
```

`terraform/modules/vpc_endpoints/outputs.tf`:

```hcl
output "vpce_security_group_id" { value = aws_security_group.vpce.id }
```

---

### 1-6. IAMモジュール作成

`terraform/modules/iam/main.tf`:

```hcl
# ============================================================
# ECSタスク実行ロール
# ECRからイメージをPullし、CloudWatch Logsに書き込むために必要
# ============================================================
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.name_prefix}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ============================================================
# ECSタスクロール
# 前処理コンテナがS3の入力データを読み、結果をS3に書くために必要
# ============================================================
resource "aws_iam_role" "ecs_task" {
  name = "${var.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "s3-access"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 入力ファイルの読み取り専用
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.input_bucket_arn}/*"
      },
      {
        # 前処理後データの書き込み
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.output_bucket_arn}/*"
      }
    ]
  })
}

# ============================================================
# Lambda実行ロール（Bedrock推論）
# Bedrockモデルの呼び出しとDynamoDB書き込みのみ許可
# ============================================================
resource "aws_iam_role" "lambda_bedrock" {
  name = "${var.name_prefix}-lambda-bedrock-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_bedrock_basic" {
  role       = aws_iam_role.lambda_bedrock.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_bedrock_permissions" {
  name = "bedrock-dynamodb-s3"
  role = aws_iam_role.lambda_bedrock.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        # haiku固定でコスト暴走を防止
        Resource = "arn:aws:bedrock:${var.region}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = var.dynamodb_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.output_bucket_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/aip/*"
      }
    ]
  })
}

# ============================================================
# Lambda実行ロール（Chatwork通知）
# SSMからトークン取得のみ。Bedrockは触れない
# ============================================================
resource "aws_iam_role" "lambda_notify" {
  name = "${var.name_prefix}-lambda-notify-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_notify_basic" {
  role       = aws_iam_role.lambda_notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_notify_ssm" {
  name = "ssm-chatwork-token"
  role = aws_iam_role.lambda_notify.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/aip/*/chatwork/*"
    }]
  })
}

# ============================================================
# Step Functions実行ロール
# ECSタスク起動とLambda呼び出しのみに絞る
# ============================================================
resource "aws_iam_role" "sfn" {
  name = "${var.name_prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_permissions" {
  name = "sfn-ecs-lambda"
  role = aws_iam_role.sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks",
        ]
        Resource = "*"
      },
      {
        # ECSタスクにIAMロールを渡すための権限
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.ecs_task.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = var.lambda_arns
      },
      {
        # ECSタスクの完了をイベント駆動で待機するために必要
        Effect   = "Allow"
        Action   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
        Resource = "arn:aws:events:${var.region}:${var.account_id}:rule/StepFunctionsGetEventsForECSTaskRule"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:PutLogEvents", "logs:GetLogDelivery",
                    "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries",
                    "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}

# ============================================================
# EventBridge実行ロール
# S3イベントを受け取りStep Functionsを起動するための最小権限
# ============================================================
resource "aws_iam_role" "eventbridge" {
  name = "${var.name_prefix}-eventbridge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_sfn" {
  name = "start-sfn"
  role = aws_iam_role.eventbridge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = var.sfn_arn
    }]
  })
}
```

`terraform/modules/iam/variables.tf`:

```hcl
variable "name_prefix"        { type = string }
variable "region"             { type = string }
variable "account_id"         { type = string }
variable "input_bucket_arn"   { type = string }
variable "output_bucket_arn"  { type = string }
variable "dynamodb_table_arn" { type = string }
variable "lambda_arns"        { type = list(string) }
variable "sfn_arn"            { type = string }
```

`terraform/modules/iam/outputs.tf`:

```hcl
output "ecs_task_execution_role_arn" { value = aws_iam_role.ecs_task_execution.arn }
output "ecs_task_role_arn"           { value = aws_iam_role.ecs_task.arn }
output "lambda_bedrock_role_arn"     { value = aws_iam_role.lambda_bedrock.arn }
output "lambda_notify_role_arn"      { value = aws_iam_role.lambda_notify.arn }
output "sfn_role_arn"                { value = aws_iam_role.sfn.arn }
output "eventbridge_role_arn"        { value = aws_iam_role.eventbridge.arn }
```

---

### 1-7. environments/dev から各モジュールを呼び出す

`terraform/environments/dev/main.tf` に以下を追記する（前のステップで作成した骨格に続けて）:

```hcl
# データソース: 既存VPCのルートテーブルIDを取得
data "aws_route_tables" "private" {
  vpc_id = var.vpc_id
  filter {
    name   = "association.main"
    values = ["false"]
  }
}

module "vpc_endpoints" {
  source             = "../../modules/vpc_endpoints"
  name_prefix        = local.name_prefix
  vpc_id             = var.vpc_id
  vpc_cidr           = var.vpc_cidr
  region             = var.aws_region
  private_subnet_ids = var.private_subnet_ids
  route_table_ids    = data.aws_route_tables.private.ids
}

module "s3" {
  source      = "../../modules/s3"
  name_prefix = local.name_prefix
  account_id  = var.aws_account_id
}

module "dynamodb" {
  source      = "../../modules/dynamodb"
  name_prefix = local.name_prefix
}

module "ecr" {
  source      = "../../modules/ecr"
  env         = var.env
  name_prefix = local.name_prefix
}

# IAMはphase3でLambda ARNが確定してから追記
# module "iam" { ... }
```

`terraform/environments/dev/outputs.tf`:

```hcl
output "input_bucket_name"  { value = module.s3.input_bucket_name }
output "output_bucket_name" { value = module.s3.output_bucket_name }
output "dynamodb_table_name" { value = module.dynamodb.table_name }
output "ecr_repository_url" { value = module.ecr.repository_url }
```

---

### 1-8. 初期化・planの実行

```bash
cd terraform/environments/dev
terraform init
terraform fmt -recursive ../../
terraform validate
terraform plan
```

エラーがなければ apply する:

```bash
terraform apply -auto-approve
```

---

## 完了チェックリスト

- [ ] `terraform apply` がエラーなく完了する
- [ ] S3バケット2つ（input/output）が作成されている
- [ ] DynamoDBテーブル `aip-dev-results` が作成されている
- [ ] ECRリポジトリ `aip/dev/preprocessor` が作成されている
- [ ] VPC Endpointが8個以上作成されている
- [ ] NAT Gatewayが0個であることを確認

```bash
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" --query 'NatGateways[].NatGatewayId'
# [] が返れば正しい
```

## 口頭説明チェックポイント（ADR準備）
以下の問いに対して、メモなしで1分以上説明できるか確認すること:
- 「なぜNAT GatewayではなくVPC Endpointを使うのか？」
- 「Gateway型とInterface型のVPC Endpointの違いは何か？」
- 「ECSタスクロールとタスク実行ロールの役割の違いは？」