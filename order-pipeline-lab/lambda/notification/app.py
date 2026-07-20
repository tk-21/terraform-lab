"""
通知送信 Lambda
注文完了または失敗時にユーザーへの通知を行う。
"""
import os
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
