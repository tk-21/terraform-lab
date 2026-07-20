# Phase 1 — 基盤インフラ構築 (Kinesis / DynamoDB / ECR)

## 目標
ストリーム処理パイプラインの土台となるAWSリソースをTerraformで構築する。
Lambdaコードは次フェーズで扱うため、今フェーズはデータ基盤とコンテナレジストリに集中する。

---

## Step 1: Terraformプロジェクト初期化

以下のファイルを作成する。

### `terraform/main.tf`
```hcl
# ap-northeast-1 (東京) リージョンを使用
# 理由: 物理的に近く、レイテンシが低い
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
}

# アカウントIDをハードコードせずdata sourceで取得する
# 理由: 複数アカウントでの再利用性とセキュリティのため
data "aws_caller_identity" "current" {}

module "kinesis" {
  source       = "./modules/kinesis"
  project_name = var.project_name
}

module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
}
```

### `terraform/variables.tf`
```hcl
variable "aws_region" {
  description = "デプロイ先AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "全リソースに付与するプロジェクト名プレフィックス"
  type        = string
  default     = "iot-pipeline"
}
```

### `terraform/outputs.tf`
```hcl
output "kinesis_stream_name" {
  description = "Kinesisストリーム名 (Phase2のLambda設定で使用)"
  value       = module.kinesis.stream_name
}

output "kinesis_stream_arn" {
  description = "KinesisストリームARN"
  value       = module.kinesis.stream_arn
}

output "dynamodb_table_name" {
  description = "DynamoDBテーブル名"
  value       = module.dynamodb.table_name
}

output "dynamodb_table_arn" {
  description = "DynamoDBテーブルARN (IAMポリシーで使用)"
  value       = module.dynamodb.table_arn
}

output "ecr_processor_url" {
  description = "processorコンテナのECRリポジトリURL"
  value       = module.ecr.processor_repository_url
}

output "ecr_reader_url" {
  description = "readerコンテナのECRリポジトリURL"
  value       = module.ecr.reader_repository_url
}

output "aws_account_id" {
  description = "AWSアカウントID (ECR認証で使用)"
  value       = data.aws_caller_identity.current.account_id
}
```

---

## Step 2: Kinesisモジュール作成

### `terraform/modules/kinesis/main.tf`
```hcl
# オンデマンドモードを選択する
# 理由: シャード数を事前見積もりせずにコスト最適化できる。
#       ハンズオン用途では流量が予測しにくいため。
resource "aws_kinesis_stream" "sensor" {
  name        = "${var.project_name}-stream"
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  # 保持期間は24時間 (デフォルト) で十分
  # 理由: ハンズオン用途では再処理より即時処理を重視する
  retention_period = 24

  tags = {
    Project = var.project_name
    Purpose = "IoTセンサーデータのリアルタイムストリーム"
  }
}
```

### `terraform/modules/kinesis/variables.tf`
```hcl
variable "project_name" {
  type = string
}
```

### `terraform/modules/kinesis/outputs.tf`
```hcl
output "stream_name" {
  value = aws_kinesis_stream.sensor.name
}

output "stream_arn" {
  value = aws_kinesis_stream.sensor.arn
}
```

---

## Step 3: DynamoDBモジュール作成

### `terraform/modules/dynamodb/main.tf`
```hcl
# PAY_PER_REQUESTを選択する
# 理由: ハンズオン用途ではトラフィックが断続的のため、
#       プロビジョニングキャパシティより従量課金の方がコストが低い
resource "aws_dynamodb_table" "sensor_data" {
  name         = "${var.project_name}-table"
  billing_mode = "PAY_PER_REQUEST"

  # パーティションキー: device_id
  # 理由: センサーごとにデータを分散させ、ホットパーティションを避ける
  hash_key  = "device_id"

  # ソートキー: timestamp
  # 理由: デバイスごとの時系列クエリを効率化するため
  range_key = "timestamp"

  attribute {
    name = "device_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  # TTLを設定する
  # 理由: ハンズオンデータが永続化されてコストが増加しないよう、
  #       72時間後に自動削除する
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Project = var.project_name
    Purpose = "センサーデータの永続化ストア"
  }
}
```

### `terraform/modules/dynamodb/variables.tf`
```hcl
variable "project_name" {
  type = string
}
```

### `terraform/modules/dynamodb/outputs.tf`
```hcl
output "table_name" {
  value = aws_dynamodb_table.sensor_data.name
}

output "table_arn" {
  value = aws_dynamodb_table.sensor_data.arn
}
```

---

## Step 4: ECRモジュール作成

### `terraform/modules/ecr/main.tf`
```hcl
# processorとreaderで別リポジトリを作成する
# 理由: デプロイサイクルが異なるため、独立したライフサイクル管理が必要

resource "aws_ecr_repository" "processor" {
  name                 = "${var.project_name}-processor"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # プッシュ時に脆弱性スキャンを実行する
    # 理由: コンテナイメージのセキュリティリスクを早期検出するため
    scan_on_push = true
  }

  tags = {
    Project = var.project_name
    Role    = "Kinesisイベント処理Lambda"
  }
}

resource "aws_ecr_repository" "reader" {
  name                 = "${var.project_name}-reader"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = var.project_name
    Role    = "API Gateway経由のDynamoDB読み取りLambda"
  }
}

# 古いイメージを自動削除するライフサイクルポリシー
# 理由: ECRストレージコストを抑えるため、最新1世代のみ保持する
resource "aws_ecr_lifecycle_policy" "processor" {
  repository = aws_ecr_repository.processor.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新イメージ1件のみ保持"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "reader" {
  repository = aws_ecr_repository.reader.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新イメージ1件のみ保持"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}
```

### `terraform/modules/ecr/variables.tf`
```hcl
variable "project_name" {
  type = string
}
```

### `terraform/modules/ecr/outputs.tf`
```hcl
output "processor_repository_url" {
  value = aws_ecr_repository.processor.repository_url
}

output "reader_repository_url" {
  value = aws_ecr_repository.reader.repository_url
}
```

---

## Step 5: Terraform実行

```bash
cd terraform
terraform init
terraform plan
terraform apply -auto-approve

# outputsを確認・保存する (Phase2で使用)
terraform output -json > ../phase1_outputs.json
cat ../phase1_outputs.json
```

---

## 完了チェックリスト

実行後、以下をAWSコンソールまたはCLIで確認すること:

```bash
# Kinesisストリームがアクティブか
aws kinesis describe-stream-summary \
  --stream-name iot-pipeline-stream \
  --query 'StreamDescriptionSummary.StreamStatus'

# DynamoDBテーブルが存在するか
aws dynamodb describe-table \
  --table-name iot-pipeline-table \
  --query 'Table.TableStatus'

# ECRリポジトリが2つ作成されているか
aws ecr describe-repositories \
  --query 'repositories[*].repositoryName'
```

---

## 口頭説明チェックポイント ✅

Phase2に進む前に、以下を自分の言葉で説明できるか確認する:

1. **なぜKinesisのオンデマンドモードを選んだか？** (シャード管理コストとの比較)
2. **DynamoDBのパーティションキーにdevice_idを選んだ理由は？** (ホットパーティション回避)
3. **TTLを設定した目的は？** (コストとデータライフサイクルの観点から)
4. **ECRのライフサイクルポリシーがない場合に何が起きるか？**