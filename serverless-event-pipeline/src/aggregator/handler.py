"""
aggregator Lambda — DynamoDB Streams トリガーによる集計処理

【DynamoDB Streams の特性: 最低1回配信（at-least-once delivery）】
  DynamoDB Streams はシャードごとにレコードを順序保証付きで配信するが、
  同一レコードが複数回配信される可能性がある（at-least-once）。
  これを考慮し、以下の設計で重複処理の影響を最小化する:

    1. MODIFY イベントでは NewImage と OldImage の差分のみ集計する
       → 同じ MODIFY レコードが再配信されても差分は変わらないため影響がない
    2. INSERT の PURCHASE: 再配信された場合は二重加算になりうる
       → 本実装の許容範囲とし、監視メトリクスで検知する設計とする
       → 完全な冪等性が必要な場合は sequence_number を外部ストアに記録する
    3. UpdateItem は ADD 式（アトミック加算）を使用する
       → 競合状態（同時書き込み）をデータベースレベルで防ぐ

【処理フロー】
  DynamoDB Streams イベント
    → REMOVE はスキップ（ログのみ）
    → INSERT / MODIFY を entity_id + 日付でグループ化
    → PURCHASE: TOTAL_AMOUNT と count を ADD 式でアトミック加算
    → VIEW:     VIEW_COUNT と count を ADD 式でアトミック加算
"""

import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext
from boto3.dynamodb.types import TypeDeserializer
from shared.utils import build_tracer

logger = Logger()
tracer = build_tracer()
metrics = Metrics(namespace="ServerlessEventPipeline")

# TypeDeserializer: DynamoDB Streams の TypedDict フォーマットを Python 型に変換する。
# 例: {"entity_id": {"S": "USER#u123"}, "value": {"N": "100"}}
#   → {"entity_id": "USER#u123", "value": Decimal("100")}
_deserializer = TypeDeserializer()


def _get_table():
    """集計テーブルの DynamoDB リソースを返す（テスト時にモック可能）。"""
    table_name = os.environ["AGGREGATIONS_TABLE_NAME"]
    dynamodb = boto3.resource("dynamodb")
    return dynamodb.Table(table_name)


def _deserialize_image(image: dict) -> dict:
    """DynamoDB Streams の TypedDict フォーマットを Python dict に変換する。"""
    return {k: _deserializer.deserialize(v) for k, v in image.items()}


def _extract_date(event_ts: str) -> str:
    """
    DynamoDB SK のイベントタイムスタンプから日付部分を抽出する。

    例: "EVENT#2024-01-15T12:00:00Z" → "2024-01-15"
    """
    # SK フォーマット: "EVENT#<ISO8601>" → "#" 以降を取得
    ts_str = event_ts.split("#", 1)[-1] if "#" in event_ts else event_ts
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d")
    except ValueError:
        # パース失敗時は先頭 10 文字（YYYY-MM-DD）を使用（処理継続を優先）
        logger.warning("event_ts のパースに失敗しました", extra={"event_ts": event_ts})
        return ts_str[:10]


def _process_record(record: dict) -> list:
    """
    単一の DynamoDB Streams レコードを集計オペレーションのリストに変換する。

    Returns:
        list[dict]: 集計オペレーションのリスト。各要素は以下のキーを持つ。
          aggregate_key (str)     — 例: "USER#u123#2024-01-15"
          metric_type   (str)     — "TOTAL_AMOUNT" / "VIEW_COUNT"
          value_delta   (Decimal) — 加算する集計値
          count_delta   (int)     — 加算するカウント
    """
    event_name = record["eventName"]

    # REMOVE イベントはスキップ。
    # 削除による集計の減算は複雑性が高く、イベント駆動集計では一般的に行わない。
    if event_name == "REMOVE":
        logger.info(
            "REMOVE イベントをスキップします",
            extra={"event_id": record.get("eventID"), "event_name": event_name},
        )
        return []

    dynamodb_record = record.get("dynamodb", {})
    new_image = _deserialize_image(dynamodb_record.get("NewImage", {}))

    # OldImage は INSERT には存在しない。MODIFY の場合のみ提供される。
    old_image = (
        _deserialize_image(dynamodb_record["OldImage"])
        if "OldImage" in dynamodb_record
        else {}
    )

    entity_id = new_image.get("entity_id", "")
    event_ts = new_image.get("event_ts", "")

    if not entity_id or not event_ts:
        logger.warning(
            "entity_id または event_ts が欠損しています（レコードをスキップ）",
            extra={"new_image_keys": list(new_image.keys()), "event_id": record.get("eventID")},
        )
        return []

    # payload は ingestor が書き込んだ辞書型フィールド。
    # DynamoDB の Map 型は TypeDeserializer で dict に変換される。
    payload = new_image.get("payload", {})
    event_type = str(payload.get("event_type", "")).upper()

    date_str = _extract_date(event_ts)
    # 集計キー: entity_id（例: USER#u123）+ 日付（例: 2024-01-15）
    aggregate_key = f"{entity_id}#{date_str}"

    operations = []

    if event_type == "PURCHASE":
        new_amount = Decimal(str(payload.get("value") or 0))

        # MODIFY の場合: 旧イメージとの差分のみ加算する。
        # 【理由】DynamoDB Streams の at-least-once 配信で同じ MODIFY が再配信されても、
        # 差分は 0 になることが多く二重集計の影響を抑制できる。
        # INSERT の場合: 新規イベントなので金額全体を加算する。
        if event_name == "MODIFY":
            old_payload = old_image.get("payload", {}) if old_image else {}
            old_amount = Decimal(str(old_payload.get("value") or 0))
            value_delta = new_amount - old_amount
            # MODIFY は既存イベントの更新のため count は加算しない（二重カウント禁止）
            count_delta = 0
        else:  # INSERT
            value_delta = new_amount
            count_delta = 1

        # 差分が 0 でかつ count も変化しない場合はスキップ（不要な DynamoDB 書き込みを削減）
        if value_delta != Decimal("0") or count_delta != 0:
            operations.append({
                "aggregate_key": aggregate_key,
                "metric_type": "TOTAL_AMOUNT",
                "value_delta": value_delta,
                "count_delta": count_delta,
            })

    elif event_type == "VIEW":
        # VIEW の MODIFY: ステータス変更など内容は変化しない。
        # INSERT のみ view_count と count を加算する。
        if event_name == "INSERT":
            operations.append({
                "aggregate_key": aggregate_key,
                "metric_type": "VIEW_COUNT",
                "value_delta": Decimal("1"),
                "count_delta": 1,
            })
        # MODIFY は集計値の変化なしのためオペレーションを生成しない

    else:
        logger.debug(
            "集計対象外のイベント種別をスキップします",
            extra={"event_type": event_type, "entity_id": entity_id},
        )

    return operations


@tracer.capture_method
def _update_aggregation(
    table,
    aggregate_key: str,
    metric_type: str,
    value_delta: Decimal,
    count_delta: int,
) -> None:
    """
    DynamoDB aggregations テーブルをアトミック加算で更新する。

    ADD 式の特性（PutItem / UpdateItem との違い）:
      - 項目が存在しない場合は 0 から開始して自動作成（upsert）される
      - 項目が存在する場合は既存値に加算される
      - 並行する複数の Lambda が同一キーを更新しても競合しない（データベースレベルで処理）
      - アプリケーション側での楽観的ロック（条件式 + リトライ）が不要になる

    DynamoDB 予約語の回避:
      "value" と "count" は DynamoDB 予約語のため ExpressionAttributeNames でエイリアスが必要。
    """
    updated_at = datetime.now(tz=timezone.utc).isoformat()

    table.update_item(
        Key={
            "aggregate_key": aggregate_key,
            "metric_type": metric_type,
        },
        # ADD と SET を同一 UpdateExpression で使用できる。
        #   ADD: value・count をアトミック加算（項目未存在時は 0 を初期値として扱う）
        #   SET: updated_at を最終更新時刻として上書き
        UpdateExpression="ADD #value :value_delta, #count :count_delta SET updated_at = :updated_at",
        ExpressionAttributeNames={
            "#value": "value",  # 予約語のためエイリアスが必要
            "#count": "count",  # 予約語のためエイリアスが必要
        },
        ExpressionAttributeValues={
            ":value_delta": value_delta,
            ":count_delta": count_delta,
            ":updated_at": updated_at,
        },
    )

    logger.debug(
        "集計テーブルを更新しました",
        extra={
            "aggregate_key": aggregate_key,
            "metric_type": metric_type,
            "value_delta": str(value_delta),
            "count_delta": count_delta,
        },
    )


@logger.inject_lambda_context()
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def lambda_handler(event: dict, context: LambdaContext) -> None:
    """
    DynamoDB Streams イベントを受信して集計処理を実行する。

    DynamoDB Streams は INSERT・MODIFY・REMOVE の3種類のイベントを配信する。
    本 Lambda は INSERT・MODIFY のみ処理し、REMOVE はスキップする。
    ESM の filter_criteria でも REMOVE を除外しているが、Lambda 側でも二重防護する。

    エラーハンドリング方針:
      個別レコードの処理エラーは記録してスキップし、他レコードの処理を継続する。
      Lambda 全体のエラーは発生させない設計とする。
      bisect_on_function_error は Lambda が例外をスローした場合に機能するが、
      本実装では個別エラーを吸収するため ESM のバッチ分割は発生しない。
    """
    records = event.get("Records", [])
    table = _get_table()

    aggregated_count = 0
    error_count = 0

    logger.info(
        "DynamoDB Streams イベントを受信しました",
        extra={"record_count": len(records)},
    )

    for record in records:
        try:
            operations = _process_record(record)
            for op in operations:
                _update_aggregation(
                    table=table,
                    aggregate_key=op["aggregate_key"],
                    metric_type=op["metric_type"],
                    value_delta=op["value_delta"],
                    count_delta=op["count_delta"],
                )
                aggregated_count += 1

        except Exception as exc:
            error_count += 1
            logger.exception(
                "レコードの集計処理に失敗しました",
                extra={
                    "event_id": record.get("eventID"),
                    "error": str(exc),
                },
            )
            # 個別レコードのエラーはスキップして処理継続する。
            # 全件失敗の場合は error_count の上昇を CloudWatch で検知する。

    # カスタムメトリクスの記録
    # AggregatedEvents: 正常に集計した操作件数（1レコードが複数オペレーションを生む場合がある）
    metrics.add_metric(name="AggregatedEvents", unit=MetricUnit.Count, value=aggregated_count)

    # AggregationErrors: エラーが1件以上あった場合のみ記録
    if error_count > 0:
        metrics.add_metric(name="AggregationErrors", unit=MetricUnit.Count, value=error_count)

    logger.info(
        "集計処理が完了しました",
        extra={
            "aggregated_count": aggregated_count,
            "error_count": error_count,
            "total_records": len(records),
        },
    )
