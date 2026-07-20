"""
在庫確認 Lambda
Step Functions から呼び出され、注文の在庫チェックを行う。
"""
import json
import os
import random
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
