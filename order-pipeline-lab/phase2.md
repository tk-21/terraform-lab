# Phase 2: Lambda 関数実装

## 目標
3つの Lambda 関数を Docker イメージなし (zip デプロイ) で実装する。
Lambda Powertools による構造化ログ・トレーシング・カスタムメトリクスを習得する。

## 作成するリソース

```
lambda/
├── inventory-check/
│   ├── app.py
│   └── requirements.txt
├── notification/
│   ├── app.py
│   └── requirements.txt
└── dlq-reprocessor/
    ├── app.py
    └── requirements.txt

terraform/modules/lambda/
├── main.tf
├── variables.tf
└── outputs.tf
```

---

## Task 1: 在庫確認 Lambda

### `lambda/inventory-check/requirements.txt`
```
aws-lambda-powertools[tracer]>=2.0.0
boto3>=1.34.0
```

### `lambda/inventory-check/app.py`
```python
"""
在庫確認 Lambda
Step Functions から呼び出され、注文の在庫チェックを行う。
"""
import json
import random
import time
import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="OrderPipeline", service="inventory-check")

dynamodb = boto3.resource("dynamodb")

@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
@metrics.log_metrics
def handler(event, context):
    """
    入力: {"order_id": "xxx", "items": [{"sku": "A001", "qty": 2}]}
    出力: {"order_id": "xxx", "inventory_ok": true/false, "reserved_items": [...]}
    """
    order_id = event["order_id"]
    items = event.get("items", [])

    logger.info("在庫確認開始", extra={"order_id": order_id, "item_count": len(items)})

    # DynamoDB に処理中ステータスを書き込む
    _update_order_status(order_id, "INVENTORY_CHECKING")

    # なぜ: 実際の在庫システムへの問い合わせを模擬
    #       本番では外部 API や DB 参照になる
    reserved_items = []
    for item in items:
        sku = item["sku"]
        qty = item["qty"]

        # なぜ: テスト用に 10% の確率で在庫切れを発生させる
        #       障害耐性テストのためのシミュレーション
        if random.random() < 0.1:
            logger.warning("在庫不足", extra={"sku": sku, "requested_qty": qty})
            metrics.add_metric(name="InventoryShortage", unit=MetricUnit.Count, value=1)

            _update_order_status(order_id, "INVENTORY_FAILED")
            return {
                "order_id": order_id,
                "inventory_ok": False,
                "reason": f"在庫不足: SKU={sku}",
                "reserved_items": []
            }

        reserved_items.append({"sku": sku, "qty": qty, "reserved": True})

    metrics.add_metric(name="InventoryCheckSuccess", unit=MetricUnit.Count, value=1)
    _update_order_status(order_id, "INVENTORY_OK")

    logger.info("在庫確認完了", extra={"order_id": order_id, "reserved_count": len(reserved_items)})

    return {
        "order_id": order_id,
        "inventory_ok": True,
        "reserved_items": reserved_items
    }


@tracer.capture_method
def _update_order_status(order_id: str, status: str):
    """DynamoDB の注文ステータスを更新する"""
    import os
    from datetime import datetime, timezone

    table_name = os.environ["DYNAMODB_TABLE_NAME"]
    table = dynamodb.Table(table_name)

    table.update_item(
        Key={"order_id": order_id},
        UpdateExpression="SET #s = :status, updated_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": status,
            ":ts": datetime.now(timezone.utc).isoformat()
        }
    )
```

---

## Task 2: 通知 Lambda

### `lambda/notification/requirements.txt`
```
aws-lambda-powertools[tracer]>=2.0.0
boto3>=1.34.0
```

### `lambda/notification/app.py`
```python
"""
通知送信 Lambda
注文完了または失敗時にユーザーへの通知を行う。
"""
import os
import json
import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="OrderPipeline", service="notification")

dynamodb = boto3.resource("dynamodb")


@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
@metrics.log_metrics
def handler(event, context):
    """
    入力: {"order_id": "xxx", "status": "COMPLETED"/"FAILED", "reason": "..."}
    """
    order_id = event["order_id"]
    status = event["status"]
    reason = event.get("reason", "")

    logger.info("通知送信開始", extra={"order_id": order_id, "status": status})

    # なぜ: 実際の通知 (メール/SMS/Chatwork) の代わりにログ出力
    #       本番では SNS Topic や Chatwork API を呼び出す
    if status == "COMPLETED":
        logger.info(
            "注文完了通知",
            extra={"order_id": order_id, "message": f"注文 {order_id} が完了しました"}
        )
        metrics.add_metric(name="NotificationSent", unit=MetricUnit.Count, value=1)
        final_status = "COMPLETED"
    else:
        logger.warning(
            "注文失敗通知",
            extra={"order_id": order_id, "reason": reason}
        )
        metrics.add_metric(name="NotificationFailed", unit=MetricUnit.Count, value=1)
        final_status = "FAILED"

    # 最終ステータスを DynamoDB に書き込む
    _finalize_order(order_id, final_status, reason)

    return {"order_id": order_id, "notification_sent": True, "final_status": final_status}


@tracer.capture_method
def _finalize_order(order_id: str, status: str, reason: str):
    from datetime import datetime, timezone

    table_name = os.environ["DYNAMODB_TABLE_NAME"]
    table = dynamodb.Table(table_name)

    table.update_item(
        Key={"order_id": order_id},
        UpdateExpression="SET #s = :status, completed_at = :ts, failure_reason = :reason",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": status,
            ":ts": datetime.now(timezone.utc).isoformat(),
            ":reason": reason
        }
    )
```

---

## Task 3: DLQ 再処理 Lambda

### `lambda/dlq-reprocessor/requirements.txt`
```
aws-lambda-powertools[tracer]>=2.0.0
boto3>=1.34.0
```

### `lambda/dlq-reprocessor/app.py`
```python
"""
DLQ 再処理 Lambda
DLQ に届いたメッセージを分析し、補償処理 (キャンセル・返金) を行う。
"""
import os
import json
import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="OrderPipeline", service="dlq-reprocessor")

dynamodb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")


@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
@metrics.log_metrics
def handler(event, context):
    """
    SQS DLQ トリガーで呼び出される。
    SQS イベントソースマッピングで DLQ を監視。
    """
    failed_orders = []
    success_count = 0

    for record in event["Records"]:
        # なぜ: 受信回数を確認することで、一時的な障害か恒久的な障害かを判断する
        receive_count = int(record["attributes"]["ApproximateReceiveCount"])
        message_id = record["messageId"]

        try:
            body = json.loads(record["body"])
            order_id = body.get("order_id", "UNKNOWN")

            logger.error(
                "DLQ メッセージ受信 - 補償処理を開始",
                extra={
                    "order_id": order_id,
                    "receive_count": receive_count,
                    "message_id": message_id
                }
            )

            # 補償処理: 注文をキャンセル状態にして在庫を解放
            _compensate_order(order_id, receive_count)

            metrics.add_metric(name="CompensationExecuted", unit=MetricUnit.Count, value=1)
            success_count += 1

        except Exception as e:
            logger.exception(
                "補償処理中にエラー発生",
                extra={"message_id": message_id, "error": str(e)}
            )
            metrics.add_metric(name="CompensationFailed", unit=MetricUnit.Count, value=1)
            failed_orders.append(message_id)

    logger.info(
        "DLQ 処理完了",
        extra={"success": success_count, "failed": len(failed_orders)}
    )

    # なぜ: 処理失敗したメッセージは例外を raise せず、
    #       batchItemFailures で個別に報告する (部分的な成功を許容)
    return {
        "batchItemFailures": [
            {"itemIdentifier": msg_id} for msg_id in failed_orders
        ]
    }


@tracer.capture_method
def _compensate_order(order_id: str, receive_count: int):
    """注文のキャンセル補償処理"""
    from datetime import datetime, timezone

    table_name = os.environ["DYNAMODB_TABLE_NAME"]
    table = dynamodb.Table(table_name)

    table.update_item(
        Key={"order_id": order_id},
        UpdateExpression=(
            "SET #s = :status, compensated_at = :ts, "
            "dlq_receive_count = :count"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": "CANCELLED_BY_DLQ",
            ":ts": datetime.now(timezone.utc).isoformat(),
            ":count": receive_count
        }
    )
    logger.info("補償処理完了 - 注文キャンセル", extra={"order_id": order_id})
```

---

## Task 4: Lambda Terraform モジュール

### `terraform/modules/lambda/variables.tf`
```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "common_tags" { type = map(string) }
variable "dynamodb_table_name" { type = string }
variable "dynamodb_table_arn" { type = string }
variable "orders_queue_arn" { type = string }
variable "orders_dlq_arn" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "vpc_endpoints_sg_id" { type = string }
variable "vpc_id" { type = string }
```

### `terraform/modules/lambda/main.tf`

IAM ロール、セキュリティグループ、Lambda 関数 (3つ)、SQS イベントソースマッピング、
CloudWatch Log Groups を以下の仕様で実装すること:

**IAM ロール (Lambda共通)**
- `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:Query` — 対象テーブルのみ
- `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` — DLQ のみ
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`
- `xray:PutTraceSegments`, `xray:PutTelemetryRecords`
- `ec2:CreateNetworkInterface`, `ec2:DescribeNetworkInterfaces`, `ec2:DeleteNetworkInterface` — VPC Lambda に必要

**セキュリティグループ (Lambda用)**
```hcl
resource "aws_security_group" "lambda" {
  name   = "${var.project}-lambda-sg"
  vpc_id = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # なぜ: VPC Endpoint への HTTPS 通信を許可
  }

  tags = merge(var.common_tags, { Name = "${var.project}-lambda-sg" })
}
```

**Lambda 関数共通設定**
```hcl
runtime       = "python3.12"
architectures = ["arm64"]  # なぜ: x86_64 比で約 20% コスト削減
timeout       = 30
memory_size   = 256

vpc_config {
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.lambda.id]
}

tracing_config {
  mode = "Active"  # なぜ: X-Ray でボトルネックを可視化するため
}

environment {
  variables = {
    DYNAMODB_TABLE_NAME  = var.dynamodb_table_name
    POWERTOOLS_SERVICE_NAME = "${var.project}-{function_name}"
    LOG_LEVEL            = "INFO"
  }
}
```

**DLQ → dlq-reprocessor のイベントソースマッピング**
```hcl
resource "aws_lambda_event_source_mapping" "dlq" {
  event_source_arn                   = var.orders_dlq_arn
  function_name                      = aws_lambda_function.dlq_reprocessor.arn
  batch_size                         = 5  # なぜ: 一度に大量処理せず、失敗時の影響範囲を限定
  maximum_batching_window_in_seconds = 30

  # なぜ: 部分的なバッチ失敗を許可し、成功したメッセージは削除する
  function_response_types = ["ReportBatchItemFailures"]
}
```

**zip パッケージングは `archive_file` data source を使用**
```hcl
data "archive_file" "inventory_check" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/inventory-check"
  output_path = "${path.root}/../.build/inventory-check.zip"
}
```

### `terraform/modules/lambda/outputs.tf`
```hcl
output "inventory_check_arn" { value = aws_lambda_function.inventory_check.arn }
output "notification_arn" { value = aws_lambda_function.notification.arn }
output "dlq_reprocessor_arn" { value = aws_lambda_function.dlq_reprocessor.arn }
output "lambda_sg_id" { value = aws_security_group.lambda.id }
```

---

## Task 5: main.tf にモジュール追加

`terraform/main.tf` に追加:
```hcl
module "lambda" {
  source = "./modules/lambda"

  project              = local.project
  environment          = local.environment
  common_tags          = local.common_tags
  dynamodb_table_name  = aws_dynamodb_table.orders.name
  dynamodb_table_arn   = aws_dynamodb_table.orders.arn
  orders_queue_arn     = module.sqs.orders_queue_arn
  orders_dlq_arn       = module.sqs.orders_dlq_arn
  private_subnet_ids   = module.networking.private_subnet_ids
  vpc_endpoints_sg_id  = module.networking.vpc_endpoints_sg_id
  vpc_id               = module.networking.vpc_id
}
```

---

## 実行手順

```bash
# .build ディレクトリ作成
mkdir -p .build

cd terraform
terraform init
terraform plan
terraform apply -auto-approve

# Lambda 単体テスト (在庫確認)
aws lambda invoke \
  --function-name order-pipeline-inventory-check \
  --payload '{"order_id":"test-001","items":[{"sku":"A001","qty":1}]}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json \
  --region ap-northeast-1

cat /tmp/response.json | jq .

# DynamoDB でステータス確認
aws dynamodb get-item \
  --table-name order-pipeline-orders \
  --key '{"order_id": {"S": "test-001"}}' \
  --region ap-northeast-1 | jq .
```

---

## フェーズ完了チェックリスト

- [ ] 3つの Lambda 関数が `terraform apply` で作成される
- [ ] `inventory-check` を直接 invoke してレスポンスが返る
- [ ] DynamoDB にステータスが書き込まれる
- [ ] CloudWatch Logs に構造化ログ (JSON) が出力される
- [ ] X-Ray トレースが確認できる
- [ ] DLQ → dlq-reprocessor の Event Source Mapping が作成されている
- [ ] Lambda が VPC 内に配置されている (subnet_ids が設定されている)

## 口頭説明チェック
「なぜ Lambda を VPC 内に配置するのか、そのトレードオフは？」を説明できるか？
「batchItemFailures の仕組みとメリット」を説明できるか？