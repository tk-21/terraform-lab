# src/stream_processor/handler.py
#
# DynamoDB Streams プロセッサー Lambda 関数。
# DynamoDB の変更イベントを受け取り、S3 に監査ログとして保存する。
#
# イベントソースマッピングの設定:
#   - batchSize: 10
#   - functionResponseTypes: [ReportBatchItemFailures]
#   → 部分的なバッチ失敗に対応。失敗したレコードのみリトライする。

import json
import os
from datetime import datetime, timezone
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.data_classes import DynamoDBStreamEvent
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="ServerlessApiPlatform")

# バケット名は環境変数から取得。ハードコード禁止（CLAUDE.md）。
AUDIT_BUCKET_NAME = os.environ["AUDIT_BUCKET_NAME"]

s3 = boto3.client("s3")


@logger.inject_lambda_context(correlation_id_path="Records[0].eventID")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """
    DynamoDB Streams のイベントを処理し、S3 に監査ログを保存する。

    Returns:
        batchItemFailures: 処理に失敗したレコードの sequenceNumber リスト。
        空リストの場合はバッチ全体が成功とみなされる。
    """
    batch_item_failures = []
    stream_event = DynamoDBStreamEvent(event)

    for record in stream_event.records:
        try:
            _process_record(record)
            metrics.add_metric(name="StreamRecordProcessed", unit=MetricUnit.Count, value=1)

        except Exception as e:
            logger.exception(
                "Failed to process stream record",
                sequence_number=record.dynamodb.sequence_number,
            )
            metrics.add_metric(name="StreamRecordFailed", unit=MetricUnit.Count, value=1)

            # ReportBatchItemFailures: 失敗したレコードのみリトライ
            batch_item_failures.append(
                {"itemIdentifier": record.dynamodb.sequence_number}
            )

    return {"batchItemFailures": batch_item_failures}


@tracer.capture_method
def _process_record(record: Any) -> None:
    """
    単一の DynamoDB Streams レコードを処理して S3 に保存する。

    S3 のパス構成:
        audit-logs/<year>/<month>/<day>/<event_name>/<sequence_number>.json
    例:
        audit-logs/2024/01/15/MODIFY/12345678901234567890123.json
    """
    now = datetime.now(timezone.utc)
    event_name = record.event_name.value  # INSERT / MODIFY / REMOVE

    # S3 のキーをタイムスタンプ + イベント種別 + シーケンス番号で構成する。
    # パーティションを日付でまとめることで、Athena でのクエリを効率化する。
    s3_key = (
        f"audit-logs/"
        f"{now.year}/{now.month:02d}/{now.day:02d}/"
        f"{event_name}/"
        f"{record.dynamodb.sequence_number}.json"
    )

    # 監査ログのペイロード
    audit_log = {
        "event_id": record.event_id,
        "event_name": event_name,
        "event_source": record.event_source,
        "aws_region": record.aws_region,
        "timestamp": now.isoformat(),
        "dynamodb": {
            "sequence_number": record.dynamodb.sequence_number,
            "size_bytes": record.dynamodb.size_bytes,
            "stream_view_type": str(record.dynamodb.stream_view_type),
            "new_image": _deserialize_image(record.dynamodb.new_image),
            "old_image": _deserialize_image(record.dynamodb.old_image),
        },
    }

    s3.put_object(
        Bucket=AUDIT_BUCKET_NAME,
        Key=s3_key,
        Body=json.dumps(audit_log, ensure_ascii=False, default=str),
        ContentType="application/json",
    )

    logger.info("Audit log saved", s3_key=s3_key, event_name=event_name)


def _deserialize_image(image: dict | None) -> dict | None:
    """
    DynamoDB の型付き形式（{"S": "value"}）を通常の dict に変換する。
    None の場合はそのまま返す。
    """
    if image is None:
        return None

    # Lambda Powertools の DynamoDBStreamEvent は既にデシリアライズ済み
    # dict に変換して返す
    if hasattr(image, "raw_event"):
        return image.raw_event
    return dict(image)
