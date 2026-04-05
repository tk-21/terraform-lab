# src/stream_processor/handler.py
#
# DynamoDB Streams プロセッサー Lambda 関数。
# DynamoDB の変更イベントを受け取り、S3 に監査ログ（JSON Lines 形式）として保存する。
#
# 監査ログの保持設計:
#   - 目的: コンプライアンス・インシデント調査・変更履歴の追跡
#   - フォーマット: JSON Lines（1行1イベント）
#     → Athena / S3 Select / Glue などバッチ分析ツールと直接連携できる
#   - パス: audit-logs/<year>/<month>/<day>/<item_id>-<timestamp>.jsonl
#     → 日付でパーティション化し、Athena のパーティションプルーニングを活用する
#   - 削除防止: S3 バケットポリシーで全プリンシパルの DeleteObject を拒否する
#     → ライフサイクルポリシーによる7年後の自動削除はバケットポリシーをバイパスするため機能する
#   - 変更追跡: DynamoDB Streams の NEW_AND_OLD_IMAGES で変更前後を完全記録する
#     → MODIFY イベントでは before/after の両方を保存し、何がどう変わったかを追跡できる
#
# イベントソースマッピングの設定（lambda-function モジュール参照）:
#   - batchSize: 100（スループット最大化）
#   - startingPosition: TRIM_HORIZON（ストリーム全体を処理）
#   - bisectOnFunctionError: true（失敗バッチを2分割してリトライし、問題レコードを特定）
#   - functionResponseTypes: [ReportBatchItemFailures]（成功済みレコードを再処理しない）

import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit, single_metric
from aws_lambda_powertools.utilities.data_classes import DynamoDBStreamEvent
from aws_lambda_powertools.utilities.typing import LambdaContext
from boto3.dynamodb.types import TypeDeserializer

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="ServerlessApiPlatform")

# バケット名は環境変数から取得。ハードコード禁止（CLAUDE.md）。
AUDIT_BUCKET_NAME = os.environ["AUDIT_BUCKET_NAME"]

s3 = boto3.client("s3")

# DynamoDB の型付き形式（{"S": "value"}）を Python ネイティブ型に変換する。
# グローバルインスタンスとして保持してオブジェクト生成コストを削減する。
_deserializer = TypeDeserializer()

# DynamoDB Stream のイベント名 → 監査ログのイベントタイプのマッピング
_EVENT_TYPE_MAP = {
    "INSERT": "ITEM_CREATED",
    "MODIFY": "ITEM_UPDATED",
    "REMOVE": "ITEM_DELETED",
}


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
        except Exception:
            logger.exception(
                "Failed to process stream record",
                sequence_number=record.dynamodb.sequence_number,
            )
            # ReportBatchItemFailures: 失敗したレコードのみリトライ。
            # bisect_on_function_error と組み合わせることで問題レコードを特定できる。
            batch_item_failures.append(
                {"itemIdentifier": record.dynamodb.sequence_number}
            )

    return {"batchItemFailures": batch_item_failures}


@tracer.capture_method
def _process_record(record) -> None:
    """
    単一の DynamoDB Streams レコードを処理して S3 に保存する。

    S3 のパス構成:
        audit-logs/<year>/<month>/<day>/<item_id>-<timestamp>.jsonl
    例:
        audit-logs/2024/01/15/item-uuid-xxxx-20240115T120000Z.jsonl
    """
    # raw_event から DynamoDB イベント名とイメージを取得する。
    # Powertools の DynamoDBStreamRecord は DictWrapper を継承しており
    # raw_event で元の dict にアクセスできる。
    raw = record.raw_event
    event_name = raw["eventName"]  # INSERT / MODIFY / REMOVE
    event_type = _EVENT_TYPE_MAP.get(event_name, event_name)

    # DynamoDB の型付き形式を Python ネイティブ型に変換する。
    # TypeDeserializer を使う理由:
    #   DynamoDB Streams のイメージは {"item_id": {"S": "uuid"}, "count": {"N": "42"}}
    #   のような型情報付き形式で届く。TypeDeserializer はすべての DynamoDB 型
    #   （S/N/B/SS/NS/BS/M/L/NULL/BOOL）を正確に Python ネイティブ型に変換できる。
    dynamodb_data = raw.get("dynamodb", {})
    new_image = _deserialize_image(dynamodb_data.get("NewImage"))
    old_image = _deserialize_image(dynamodb_data.get("OldImage"))

    # item_id は new_image または old_image から取得する。
    # REMOVE イベントでは new_image が存在しないため old_image にフォールバックする。
    source_image = new_image or old_image or {}
    item_id = source_image.get("item_id", "unknown")
    user_id = source_image.get("user_id", "unknown")

    now = datetime.now(timezone.utc)
    timestamp_str = now.strftime("%Y%m%dT%H%M%SZ")

    # S3 のキーを日付パーティション + item_id + タイムスタンプで構成する。
    # 同一 item_id への複数変更は異なるタイムスタンプで別ファイルとして保存される。
    # パーティションキーを日付にすることで Athena のクエリ範囲を限定できる。
    s3_key = (
        f"audit-logs/"
        f"{now.year}/{now.month:02d}/{now.day:02d}/"
        f"{item_id}-{timestamp_str}.jsonl"
    )

    # 監査ログのペイロード（CLAUDE.md の設計方針に基づくフォーマット）
    audit_log = {
        "event_type": event_type,
        "item_id": item_id,
        "user_id": user_id,
        "changed_at": now.isoformat(),
        "changes": _build_changes(event_name, new_image, old_image),
    }

    # JSON Lines 形式（1イベント1行）で保存する。
    # ensure_ascii=False: 日本語などの非 ASCII 文字をそのまま保存する。
    # default=_json_serializer: Decimal など JSON 非対応の型を文字列に変換する。
    body = json.dumps(audit_log, ensure_ascii=False, default=_json_serializer) + "\n"

    s3.put_object(
        Bucket=AUDIT_BUCKET_NAME,
        Key=s3_key,
        Body=body.encode("utf-8"),
        ContentType="application/x-ndjson",
    )

    logger.info(
        "Audit log saved",
        s3_key=s3_key,
        event_type=event_type,
        item_id=item_id,
    )

    # カスタムメトリクス: イベントタイプ別に AuditEventsProcessed をカウントする。
    # single_metric を使ってイベントタイプを次元として即時送信する。
    # グローバルな Metrics オブジェクトの次元を汚染しないため single_metric が適切。
    with single_metric(
        name="AuditEventsProcessed",
        unit=MetricUnit.Count,
        value=1,
        namespace="ServerlessApiPlatform",
    ) as m:
        m.add_dimension(name="EventType", value=event_type)


def _build_changes(
    event_name: str,
    new_image: dict | None,
    old_image: dict | None,
) -> dict:
    """
    イベントタイプに応じた changes オブジェクトを構築する。

    - INSERT: after のみ（新規作成のため before なし）
    - MODIFY: before と after の両方（変更前後を記録）
    - REMOVE: before のみ（削除済みのため after なし）
    """
    changes: dict = {}

    if event_name in ("MODIFY", "REMOVE") and old_image is not None:
        changes["before"] = old_image

    if event_name in ("INSERT", "MODIFY") and new_image is not None:
        changes["after"] = new_image

    return changes


def _deserialize_image(image: dict | None) -> dict | None:
    """
    DynamoDB の型付き形式（{"S": "value"}, {"N": "123"} 等）を
    Python ネイティブ型に変換する。

    例:
        入力: {"item_id": {"S": "uuid"}, "count": {"N": "42"}, "active": {"BOOL": True}}
        出力: {"item_id": "uuid", "count": Decimal("42"), "active": True}

    N（数値）は Decimal に変換されるため、JSON 出力時は _json_serializer で str に変換する。
    """
    if image is None:
        return None

    return {
        key: _deserializer.deserialize(value)
        for key, value in image.items()
    }


def _json_serializer(obj) -> str:
    """
    JSON 非対応の型を変換するカスタムシリアライザー。
    DynamoDB の数値型は boto3 の TypeDeserializer で Decimal に変換されるため、
    JSON シリアライズ時に変換が必要。
    """
    if isinstance(obj, Decimal):
        # float への変換は精度劣化のリスクがあるため str として保存する
        return str(obj)
    return str(obj)
