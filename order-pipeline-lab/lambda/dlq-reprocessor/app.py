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
