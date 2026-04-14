"""
transformer Lambda — Kinesis Data Streams → DynamoDB パイプライン

Kinesis Data Streams からイベントを受け取り、変換後に DynamoDB へ BatchWriteItem する。
Powertools BatchProcessor（KinesisDataStreams）で部分バッチ失敗を実装する。

処理フロー:
  Kinesis ESM バッチ受信
    → BatchProcessor: 各レコードを base64 デコード → JSON パース → バリデーション → 変換
    → 成功レコードのみ DynamoDB BatchWriteItem（25 件ずつ分割 + UnprocessedItems 再試行）
    → Kinesis チェックポイント制御: batchItemFailures で失敗シーケンス番号を返す

Kinesis チェックポイントの仕組み:
  - ReportBatchItemFailures を返すと、失敗したレコードの「最小シーケンス番号」より前の
    レコードはチェックポイントが進む（再処理されない）
  - 失敗シーケンス番号以降のレコードのみが再処理対象になる
  - bisect_batch_on_function_error と組み合わせることで毒メッセージを効率的に隔離できる
"""

import json
import os
import time
from typing import Any

import boto3
from boto3.dynamodb.types import TypeSerializer
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit, single_metric
from aws_lambda_powertools.utilities.batch import (
    BatchProcessor,
    EventType,
)
from aws_lambda_powertools.utilities.data_classes.kinesis_stream_event import KinesisStreamRecord
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.utils import build_tracer, to_dynamodb_compatible
from transformer.transform import transform_record, TransformError

logger = Logger()
tracer = build_tracer()
metrics = Metrics(namespace="ServerlessEventPipeline")

# ── Kinesis ESM 対応の BatchProcessor ──────────────────────────

# EventType.KinesisDataStreams を指定することで:
#   - チェックポイントキーとしてシーケンス番号を使用する
#   - batchItemFailures レスポンスに itemIdentifier（シーケンス番号）を含める
#   - Powertools が base64 デコードを自動で処理する
processor = BatchProcessor(event_type=EventType.KinesisDataStreams)

# ── AWS クライアント（モジュールレベルで初期化してコールドスタートを最適化）──

DYNAMODB_TABLE = os.environ["EVENTS_TABLE_NAME"]

# DynamoDB クライアント: BatchWriteItem の UnprocessedItems を明示的に制御するために
# 低レベルクライアントを使用する（Table.batch_writer() は内部でリトライするが
# エラーメトリクスの計測ができないため）
_dynamodb_client = boto3.client("dynamodb")

# TypeSerializer: Python の型を DynamoDB AttributeValue 形式に変換する
# boto3.resource の Table.put_item は自動変換するが、
# client.batch_write_item は AttributeValue 形式を要求するため手動変換が必要
_serializer = TypeSerializer()

# DynamoDB BatchWriteItem の 1 リクエストあたりの最大アイテム数（AWS 仕様）
_DYNAMODB_BATCH_LIMIT = 25

# UnprocessedItems の最大リトライ回数
_MAX_UNPROCESSED_RETRIES = 3


# ── レコードハンドラ（BatchProcessor のコールバック）──────────


def record_handler(record: KinesisStreamRecord) -> dict[str, Any]:
    """
    1 Kinesis レコードをデコード・バリデーション・変換する。

    Kinesis シャードとイテレータの仕組み:
      - 各シャードは独立したイテレータを持ち、レコードの順序を保証する
      - このハンドラが例外を throw すると BatchProcessor がそのレコードを失敗扱いにし、
        シーケンス番号を batchItemFailures に追加する
      - 成功したレコードはチェックポイントが進み、再処理されない

    Args:
        record: Powertools が base64 デコードした KinesisStreamRecord

    Returns:
        transform_record() が返す DynamoDB アイテム形式の辞書

    Raises:
        TransformError: バリデーション失敗・未対応イベントタイプ
        json.JSONDecodeError: レコードデータが不正な JSON の場合
    """
    # Powertools のバージョンにより data の公開位置が異なるため両方に対応する。
    # - テストダブル: record.data にデコード済み文字列を保持
    # - 現行 Powertools: record.kinesis.data_as_text()/data_as_json() を提供
    if hasattr(record, "data"):
        raw_data: dict[str, Any] = json.loads(record.data)
    else:
        raw_data = record.kinesis.data_as_json()

    # Kinesis レコードの到着時刻から RecordAgeSeconds を計算する。
    # approximate_arrival_timestamp: Kinesis がレコードを受け取った時刻（UTC datetime）
    # 投入から Lambda 到着までの時間を計測することで、ストリームのバックログを可視化する。
    arrival = record.kinesis.approximate_arrival_timestamp
    arrival_ts = arrival.timestamp() if hasattr(arrival, "timestamp") else float(arrival)
    record_age_seconds = time.time() - arrival_ts

    metrics.add_metric(
        name="RecordAgeSeconds",
        unit=MetricUnit.Seconds,
        value=record_age_seconds,
    )

    # transform.py の純粋関数でビジネスロジック変換を実行する
    # 変換失敗時は TransformError を throw → BatchProcessor が失敗レコードとして扱う
    transformed = transform_record(raw_data)

    event_type = raw_data.get("event_type", "UNKNOWN")

    # TransformedRecords: イベントタイプ別ディメンションで件数を記録する
    # single_metric を使用することで他のメトリクスに影響せず独立したディメンションを付与できる
    with single_metric(
        name="TransformedRecords",
        unit=MetricUnit.Count,
        value=1,
        namespace="ServerlessEventPipeline",
    ) as m:
        m.add_dimension(name="EventType", value=str(event_type).upper())

    logger.info(
        "レコード変換完了",
        extra={
            "entity_id": transformed.get("entity_id"),
            "event_type": event_type,
            "sequence_number": record.kinesis.sequence_number,
            "record_age_seconds": round(record_age_seconds, 3),
        },
    )

    return transformed


# ── Lambda ハンドラ ───────────────────────────────────────────


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    """
    Kinesis ESM トリガーの Lambda ハンドラ。

    Kinesis チェックポイント制御（ReportBatchItemFailures）:
      - 失敗したレコードの最小シーケンス番号を batchItemFailures で返す
      - Kinesis ESM はその番号以降のレコードのみ再処理する
      - それより前のレコードはチェックポイントが進み、再処理されない
      - bisect_batch_on_function_error と組み合わせると、Lambda 全体エラー時に
        バッチを二分割して問題レコードを効率的に特定できる

    Args:
        event: Kinesis ストリームイベント（Records リスト）
        context: Lambda コンテキスト

    Returns:
        {"batchItemFailures": [{"itemIdentifier": "<sequence_number>"}, ...]}
    """
    # BatchProcessor で全レコードをバリデーション・変換する
    # 失敗レコードは自動で batchItemFailures に追加される
    if not event.get("Records"):
        return {"batchItemFailures": []}

    with processor(records=event["Records"], handler=record_handler, lambda_context=context):
        processing_results = processor.process()

    batch_response = processor.response()

    # 成功したレコードの変換結果を収集して DynamoDB に一括書き込みする。
    # Powertools v3 系では process() が [("success"|"fail", payload, record), ...] を返す。
    successful_items: list[dict[str, Any]] = [
        result
        for status, result, _record in processing_results
        if status == "success"
    ]

    if successful_items:
        logger.info(
            "DynamoDB BatchWriteItem 開始",
            extra={"item_count": len(successful_items)},
        )
        _batch_write_to_dynamodb(successful_items)

    return batch_response


# ── DynamoDB BatchWriteItem ────────────────────────────────────


@tracer.capture_method
def _batch_write_to_dynamodb(items: list[dict[str, Any]]) -> None:
    """
    DynamoDB に BatchWriteItem で一括書き込みする。

    BatchWriteItem の制約（AWS 仕様）:
      - 1 リクエストあたり最大 25 アイテム
      - 1 リクエストのサイズ上限: 16 MB
      - トランザクション保証なし（部分失敗が発生しうる → UnprocessedItems で再試行）

    25 件を超えるアイテムは自動的に複数リクエストに分割される。

    Args:
        items: DynamoDB に書き込む Python dict のリスト（boto3 TypeSerializer で変換される）
    """
    # 25 件ずつのチャンクに分割して順次書き込む
    for offset in range(0, len(items), _DYNAMODB_BATCH_LIMIT):
        chunk = items[offset : offset + _DYNAMODB_BATCH_LIMIT]
        _write_chunk_with_retry(chunk)


def _write_chunk_with_retry(items: list[dict[str, Any]]) -> None:
    """
    1 チャンク（最大 25 件）を DynamoDB に書き込み、UnprocessedItems を再試行する。

    UnprocessedItems の発生原因:
      - プロビジョンドスループットの超過（CapacityExceededException）
      - テーブルの一時的な利用不可（throttling）

    再試行戦略（指数バックオフ）:
      - 1 回目: 即時
      - 2 回目: 0.1 秒待機
      - 3 回目: 0.2 秒待機
      - 4 回目: 0.4 秒待機（_MAX_UNPROCESSED_RETRIES = 3 の場合ここで打ち切り）
      最大リトライを超えた場合は BatchWriteErrors メトリクスを記録して継続する
      （チェックポイントは既に進んでいるため、失敗しても Kinesis から再読み込みされない）

    Args:
        items: DynamoDB に書き込む Python dict のリスト（最大 25 件）
    """
    # Python dict を DynamoDB AttributeValue 形式に変換する
    # TypeSerializer は None / str / int / float / bool / list / dict を自動変換する
    request_items = [
        {
            "PutRequest": {
                "Item": {
                    k: _serializer.serialize(v)
                    for k, v in to_dynamodb_compatible(item).items()
                    if v is not None
                }
            }
        }
        for item in items
    ]

    retry_count = 0
    while request_items:
        response = _dynamodb_client.batch_write_item(
            RequestItems={DYNAMODB_TABLE: request_items}
        )

        unprocessed = (
            response.get("UnprocessedItems", {}).get(DYNAMODB_TABLE, [])
        )

        if not unprocessed:
            # 全件処理完了: ループを抜ける
            break

        retry_count += 1
        if retry_count > _MAX_UNPROCESSED_RETRIES:
            # 最大リトライ超過: 件数をメトリクスに記録してループを抜ける
            # DynamoDB スロットリングが続いている場合はシャードの増加・
            # DynamoDB の WCU 増加を検討すること（runbook.md 参照）
            unprocessed_count = len(unprocessed)
            logger.error(
                "DynamoDB UnprocessedItems の再試行上限に達しました",
                extra={
                    "unprocessed_count": unprocessed_count,
                    "retry_count": retry_count,
                    "table": DYNAMODB_TABLE,
                },
            )
            metrics.add_metric(
                name="BatchWriteErrors",
                unit=MetricUnit.Count,
                value=unprocessed_count,
            )
            break

        # 指数バックオフ: 2^(retry_count-1) × 0.1 秒（例: 0.1s → 0.2s → 0.4s）
        wait_seconds = (2 ** (retry_count - 1)) * 0.1
        logger.warning(
            "DynamoDB UnprocessedItems を再試行します",
            extra={
                "unprocessed_count": len(unprocessed),
                "retry_count": retry_count,
                "wait_seconds": wait_seconds,
            },
        )
        time.sleep(wait_seconds)

        # UnprocessedItems は既に AttributeValue 形式なのでそのまま再利用する
        request_items = unprocessed
