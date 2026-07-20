# Phase 3: ECS Fargate 決済処理コンテナ

## 目標
決済処理を Docker コンテナ (ECS Fargate) で実装する。
「なぜ Lambda ではなく ECS を使うか」を設計理由として説明できるようにする。

## 設計判断: なぜ ECS Fargate か

| 観点 | Lambda | ECS Fargate |
|------|--------|-------------|
| 最大実行時間 | 15分 | 無制限 |
| メモリ上限 | 10GB | 30GB+ |
| コールドスタート | あり (秒単位) | なし (常駐) |
| ランタイム自由度 | 制限あり | 任意の Docker |
| コスト (低頻度) | 安い | 高い |

**決済処理を ECS にした理由:** 外部決済 API のタイムアウトが最大 10分の可能性があり、
Lambda の 15分制限では安全マージンが少ない。また将来の重い処理拡張性も考慮。

---

## 作成するリソース

```
ecs/payment-processor/
├── Dockerfile
├── app.py
├── requirements.txt
└── .dockerignore

terraform/modules/ecs/
├── main.tf
├── variables.tf
└── outputs.tf
```

---

## Task 1: 決済処理コンテナ実装

### `ecs/payment-processor/.dockerignore`
```
__pycache__
*.pyc
*.pyo
.env
.git
*.md
tests/
```

### `ecs/payment-processor/requirements.txt`
```
boto3>=1.34.0
requests>=2.31.0
aws-xray-sdk>=2.12.0
```

### `ecs/payment-processor/Dockerfile`
```dockerfile
# なぜ: python:3.12-slim は不要なパッケージを含まず、
#       イメージサイズを最小化してセキュリティリスクを低減
FROM python:3.12-slim

# なぜ: root 以外のユーザーで実行することで、
#       コンテナ侵害時の影響範囲を限定する
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# なぜ: requirements.txt を先にコピーすることで、
#       ソースコード変更時のキャッシュを有効活用
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# なぜ: 書き込み権限を最小化
RUN chown -R appuser:appuser /app
USER appuser

# ヘルスチェック: コンテナが正常動作しているか確認
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import sys; sys.exit(0)"

CMD ["python", "app.py"]
```

### `ecs/payment-processor/app.py`
```python
"""
決済処理 ECS タスク

Step Functions の ECS RunTask 統合で呼び出される。
環境変数で注文情報を受け取り、決済処理後に DynamoDB を更新して終了する。
"""
import os
import sys
import json
import time
import random
import logging
import boto3
from datetime import datetime, timezone

# なぜ: ECS タスクは CloudWatch Logs に直接出力するため
#       構造化ログを JSON 形式で出力する
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))


def process_payment(order_id: str, amount: int, reserved_items: list) -> dict:
    """
    決済処理のメインロジック

    なぜ: 実際の決済 API (Stripe, etc.) 呼び出しを模擬
          本番では外部 API を呼び出し、タイムアウトは最大 10分想定
    """
    logger.info(json.dumps({
        "event": "payment_start",
        "order_id": order_id,
        "amount": amount
    }))

    update_order_status(order_id, "PAYMENT_PROCESSING")

    # 決済処理のシミュレーション (2-5秒かかる処理)
    processing_time = random.uniform(2, 5)
    time.sleep(processing_time)

    # なぜ: 5% の確率で決済失敗をシミュレート
    #       Step Functions の Retry/Catch で処理されることを確認するため
    if random.random() < 0.05:
        raise PaymentGatewayException(f"決済ゲートウェイエラー: タイムアウト (order_id={order_id})")

    transaction_id = f"txn-{order_id}-{int(time.time())}"

    logger.info(json.dumps({
        "event": "payment_success",
        "order_id": order_id,
        "transaction_id": transaction_id,
        "processing_seconds": round(processing_time, 2)
    }))

    return {
        "transaction_id": transaction_id,
        "amount": amount,
        "status": "PAID"
    }


def update_order_status(order_id: str, status: str, extra: dict = None):
    """DynamoDB の注文ステータスを更新する"""
    table_name = os.environ["DYNAMODB_TABLE_NAME"]
    table = dynamodb.Table(table_name)

    update_expr = "SET #s = :status, updated_at = :ts"
    expr_values = {
        ":status": status,
        ":ts": datetime.now(timezone.utc).isoformat()
    }

    if extra:
        for key, value in extra.items():
            update_expr += f", {key} = :{key}"
            expr_values[f":{key}"] = value

    table.update_item(
        Key={"order_id": order_id},
        UpdateExpression=update_expr,
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues=expr_values
    )


class PaymentGatewayException(Exception):
    """決済ゲートウェイエラー"""
    pass


def main():
    # なぜ: Step Functions ECS RunTask 統合は環境変数でパラメータを渡す
    order_id = os.environ.get("ORDER_ID")
    amount = int(os.environ.get("AMOUNT", "0"))
    reserved_items_json = os.environ.get("RESERVED_ITEMS", "[]")

    if not order_id:
        logger.error("ORDER_ID 環境変数が設定されていません")
        sys.exit(1)

    reserved_items = json.loads(reserved_items_json)

    logger.info(json.dumps({
        "event": "task_start",
        "order_id": order_id,
        "amount": amount,
        "item_count": len(reserved_items)
    }))

    try:
        result = process_payment(order_id, amount, reserved_items)

        # 決済成功: DynamoDB を更新してタスク正常終了
        update_order_status(
            order_id,
            "PAYMENT_COMPLETED",
            {
                "transaction_id": result["transaction_id"],
                "paid_amount": result["amount"]
            }
        )

        logger.info(json.dumps({
            "event": "task_complete",
            "order_id": order_id,
            "transaction_id": result["transaction_id"]
        }))

        sys.exit(0)  # なぜ: exit code 0 = Step Functions が成功と判断

    except PaymentGatewayException as e:
        logger.error(json.dumps({
            "event": "payment_failed",
            "order_id": order_id,
            "error": str(e)
        }))
        update_order_status(order_id, "PAYMENT_FAILED")
        sys.exit(1)  # なぜ: exit code 非0 = Step Functions が失敗と判断し Retry/Catch が動作

    except Exception as e:
        logger.exception(json.dumps({
            "event": "unexpected_error",
            "order_id": order_id,
            "error": str(e)
        }))
        sys.exit(1)


if __name__ == "__main__":
    main()
```

---

## Task 2: ECR リポジトリ + ECS Terraform モジュール

### `terraform/modules/ecs/variables.tf`
```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "common_tags" { type = map(string) }
variable "private_subnet_ids" { type = list(string) }
variable "vpc_id" { type = string }
variable "dynamodb_table_name" { type = string }
variable "dynamodb_table_arn" { type = string }
variable "vpc_endpoints_sg_id" { type = string }
```

### `terraform/modules/ecs/main.tf`
以下を実装すること:

**ECR リポジトリ**
```hcl
resource "aws_ecr_repository" "payment_processor" {
  name                 = "${var.project}/payment-processor"
  image_tag_mutability = "MUTABLE"

  # なぜ: 脆弱性スキャンを自動化し、セキュリティリスクを可視化
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.common_tags, { Name = "${var.project}-payment-processor" })
}

# なぜ: 古いイメージを自動削除してストレージコストを抑制
resource "aws_ecr_lifecycle_policy" "payment_processor" {
  repository = aws_ecr_repository.payment_processor.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "最新 5世代のみ保持"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
```

**ECS Cluster**
```hcl
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  # なぜ: Container Insights で CPU/Memory/Task メトリクスを自動収集
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.common_tags, { Name = "${var.project}-cluster" })
}

# なぜ: FARGATE_SPOT を使うことでコストを最大 70% 削減
#       中断される可能性があるが、決済処理は Step Functions でリトライ可能
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 80
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 20
    base              = 1
  }
}
```

**ECS Task 実行 IAM ロール**
- `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage` — ECR pull
- `logs:CreateLogStream`, `logs:PutLogEvents` — CloudWatch Logs

**ECS Task IAM ロール (アプリ用)**
- `dynamodb:UpdateItem`, `dynamodb:GetItem` — 対象テーブルのみ
- `xray:PutTraceSegments`, `xray:PutTelemetryRecords`

**ECS Task Definition**
```hcl
resource "aws_ecs_task_definition" "payment_processor" {
  family                   = "${var.project}-payment-processor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # なぜ: arm64 で Graviton2 を使用、x86_64 比でコスト約 20% 削減
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  # なぜ: 最小構成から始める。決済処理は CPU より IO 待ちが多いため
  cpu    = 256
  memory = 512

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "payment-processor"
    image = "${aws_ecr_repository.payment_processor.repository_url}:latest"

    # なぜ: 環境変数は Step Functions から ECS RunTask 時に上書きされる
    #       ここはデフォルト値として設定
    environment = [
      { name = "DYNAMODB_TABLE_NAME", value = var.dynamodb_table_name },
      { name = "AWS_REGION", value = "ap-northeast-1" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/${var.project}/payment-processor"
        awslogs-region        = "ap-northeast-1"
        awslogs-stream-prefix = "ecs"
      }
    }

    # なぜ: 非 root ユーザーで実行 (Dockerfile の USER appuser と対応)
    user = "appuser"
  }])

  tags = merge(var.common_tags, { Name = "${var.project}-payment-processor" })
}
```

**セキュリティグループ (ECS タスク用)**
- Egress: 443/tcp → 0.0.0.0/0 (VPC Endpoint への通信のみ)
- Ingress: なし (Step Functions から直接 invoke するため)

**CloudWatch Log Group**
```hcl
resource "aws_cloudwatch_log_group" "payment_processor" {
  name              = "/ecs/${var.project}/payment-processor"
  retention_in_days = 7 # なぜ: コスト抑制のため保持期間を短縮

  tags = var.common_tags
}
```

### `terraform/modules/ecs/outputs.tf`
```hcl
output "ecr_repository_url" { value = aws_ecr_repository.payment_processor.repository_url }
output "ecs_cluster_arn" { value = aws_ecs_cluster.main.arn }
output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "task_definition_arn" { value = aws_ecs_task_definition.payment_processor.arn }
output "ecs_task_sg_id" { value = aws_security_group.ecs_task.id }
output "ecs_task_role_arn" { value = aws_iam_role.ecs_task.arn }
output "ecs_execution_role_arn" { value = aws_iam_role.ecs_execution.arn }
```

---

## Task 3: main.tf にモジュール追加

```hcl
module "ecs" {
  source = "./modules/ecs"

  project              = local.project
  environment          = local.environment
  common_tags          = local.common_tags
  private_subnet_ids   = module.networking.private_subnet_ids
  vpc_id               = module.networking.vpc_id
  dynamodb_table_name  = aws_dynamodb_table.orders.name
  dynamodb_table_arn   = aws_dynamodb_table.orders.arn
  vpc_endpoints_sg_id  = module.networking.vpc_endpoints_sg_id
}
```

---

## Task 4: Docker イメージビルド & プッシュスクリプト

### `scripts/build-and-push.sh`
```bash
#!/bin/bash
set -euo pipefail

REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
REPO_NAME="order-pipeline/payment-processor"

echo "=== ECR ログイン ==="
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ECR_URL}"

echo "=== Docker ビルド (arm64) ==="
# なぜ: --platform で arm64 を明示。Fargate の ARM64 タスクに対応
docker buildx build \
  --platform linux/arm64 \
  --tag "${ECR_URL}/${REPO_NAME}:latest" \
  --tag "${ECR_URL}/${REPO_NAME}:$(git rev-parse --short HEAD 2>/dev/null || echo 'local')" \
  --push \
  ./ecs/payment-processor/

echo "=== プッシュ完了 ==="
echo "Image: ${ECR_URL}/${REPO_NAME}:latest"
```

```bash
chmod +x scripts/build-and-push.sh
```

---

## 実行手順

```bash
# 1. Terraform 適用
cd terraform
terraform apply -auto-approve

# 2. Docker ビルド & プッシュ
mkdir -p scripts
# (build-and-push.sh を作成した後)
./scripts/build-and-push.sh

# 3. ECS タスクを手動実行してテスト
CLUSTER=$(cd terraform && terraform output -raw ecs_cluster_name 2>/dev/null || echo "order-pipeline-cluster")
TASK_DEF=$(cd terraform && terraform output -raw task_definition_arn 2>/dev/null)
SUBNET_ID=$(cd terraform && terraform output -json private_subnet_ids | jq -r '.[0]')
SG_ID=$(cd terraform && terraform output -raw ecs_task_sg_id 2>/dev/null)

aws ecs run-task \
  --cluster "${CLUSTER}" \
  --task-definition "${TASK_DEF}" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SG_ID}],assignPublicIp=DISABLED}" \
  --overrides '{
    "containerOverrides": [{
      "name": "payment-processor",
      "environment": [
        {"name": "ORDER_ID", "value": "test-001"},
        {"name": "AMOUNT", "value": "5000"},
        {"name": "RESERVED_ITEMS", "value": "[{\"sku\":\"A001\",\"qty\":2}]"}
      ]
    }]
  }' \
  --region ap-northeast-1

# 4. タスク実行状態確認
aws ecs list-tasks --cluster "${CLUSTER}" --region ap-northeast-1
```

---

## フェーズ完了チェックリスト

- [ ] `terraform apply` で ECR リポジトリ / ECS Cluster / Task Definition が作成される
- [ ] Docker イメージが ECR にプッシュされる
- [ ] ECS タスクを手動 run-task で起動できる
- [ ] CloudWatch Logs に JSON ログが出力される
- [ ] DynamoDB に `PAYMENT_COMPLETED` ステータスが書き込まれる
- [ ] タスクが exit code 0 で正常終了する
- [ ] FARGATE_SPOT が capacity provider に設定されている

## 口頭説明チェック
「Lambda と ECS Fargate の使い分け基準」を説明できるか？
「FARGATE_SPOT のリスクとそれを許容できる設計条件」を説明できるか？