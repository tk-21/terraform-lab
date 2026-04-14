"""
ingestor Lambda — S3 PUT イベント → バリデーション・正規化 → DynamoDB

処理フロー:
  1. SQS バッチから最大 batch_size 件のメッセージを受信
  2. 各 SQS メッセージボディ（S3 イベント通知）を解析して S3 オブジェクト情報を取得
  3. S3 からファイルをストリーミングダウンロード（.json / .csv 自動判定）
  4. Pydantic v2 (InputPayload) でレコードごとにバリデーション・正規化
  5. DynamoDB に条件付き PutItem（entity_id + event_ts の重複防止）
  6. Powertools カスタムメトリクスを送信（ProcessedRecords / ValidationErrors / ProcessingLatencyMs）
  7. Powertools BatchProcessor が失敗メッセージだけを batchItemFailures に追加して返す

SQS バッチ処理戦略:
  - process_partial_response: バッチ内の一部失敗を個別に制御する
  - 成功メッセージは自動削除、失敗メッセージのみ再試行対象になる
  - Lambda ESM の ReportBatchItemFailures + bisect_batch_on_function_error と組み合わせる

Lambda 環境変数（必須）:
  EVENTS_TABLE_NAME   : DynamoDB テーブル名（例: sep-dev-events）
  POWERTOOLS_SERVICE_NAME: Lambda 関数名（lambda-function モジュールが自動設定）
  LOG_LEVEL           : ログレベル（lambda-function モジュールが自動設定、デフォルト: INFO）
"""

import csv
import io
import json
import time
from datetime import datetime, timezone
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.batch import (
    BatchProcessor,
    EventType,
    process_partial_response,
)
from aws_lambda_powertools.utilities.batch.types import PartialItemFailureResponse
from aws_lambda_powertools.utilities.data_classes.sqs_event import SQSRecord
from aws_lambda_powertools.utilities.typing import LambdaContext
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError
from pydantic import ValidationError

from shared.models import EventRecord, EventStatus, InputPayload
from shared.utils import (
    build_tracer,
    get_env,
    make_event_sk,
    to_dynamodb_compatible,
    ttl_after_days,
)
from ingestor.validator import S3Object, detect_format, parse_s3_notification

# ── Powertools 初期化 ─────────────────────────────────────────
# モジュールレベルで初期化することでコールドスタート時のオーバーヘッドを一度だけ支払う。
# POWERTOOLS_SERVICE_NAME 環境変数は lambda-function モジュールが自動設定する。
logger = Logger()
tracer = build_tracer()
metrics = Metrics(namespace="ServerlessEventPipeline")

# SQS バッチプロセッサ: バッチ内の各レコードを個別処理して部分失敗を管理する
processor = BatchProcessor(event_type=EventType.SQS)

# ── AWS クライアント初期化 ────────────────────────────────────
# コールドスタート時に一度だけ初期化し、ウォームスタートで接続を再利用する（レイテンシ削減）。
s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


def _get_table() -> Any:
    """
    DynamoDB テーブルリソースを返す。
    テーブル名は環境変数 EVENTS_TABLE_NAME から取得する（ハードコード禁止）。
    """
    table_name = get_env("EVENTS_TABLE_NAME")
    return dynamodb.Table(table_name)


@tracer.capture_method
def _download_s3_streaming(bucket: str, key: str) -> list[dict]:
    """
    S3 オブジェクトをストリーミングで読み込み、レコードのリストを返す。

    フォーマット別の処理:
      JSON: boto3 StreamingBody からバイト読み込み → JSON パース
            現状はファイル全体をメモリに保持。超大容量ファイルが必要になった場合は
            ijson ライブラリによるストリーミング JSON パースへの移行を検討する。
      CSV:  StreamingBody を io.TextIOWrapper でラップして DictReader に渡す。
            ヘッダー行を自動的にキー名として使用し、行ごとに dict を生成する。
            TextIOWrapper のラップにより 1 行ずつ読み込むことでメモリ効率を高める。

    Args:
        bucket: S3 バケット名
        key:    S3 オブジェクトキー（URL デコード済み）

    Returns:
        レコードの dict リスト。単一オブジェクトの JSON も 1 要素のリストとして返す。

    Raises:
        ValueError:  未対応ファイル形式（detect_format が raise）
        ClientError: S3 GetObject 失敗（権限不足・オブジェクト不存在など）
    """
    fmt = detect_format(key)

    logger.info(
        "S3 オブジェクトのダウンロード開始",
        extra={"bucket": bucket, "key": key, "format": fmt},
    )

    response = s3_client.get_object(Bucket=bucket, Key=key)
    body = response["Body"]  # botocore.response.StreamingBody

    try:
        if fmt == "json":
            # JSON: 全体をバイト列として読み込んでパース
            raw_bytes = body.read()
            data = json.loads(raw_bytes.decode("utf-8"))
            # トップレベルがリストの場合はそのまま、オブジェクトの場合は 1 要素リストに包む
            return data if isinstance(data, list) else [data]

        else:  # csv
            # CSV: StreamingBody を TextIOWrapper に渡してストリーミング読み込みする。
            # io.TextIOWrapper は InputStream インターフェースを実装するオブジェクトを受け取り、
            # 内部バッファリングで効率的にテキストとして読み込む。
            text_stream = io.TextIOWrapper(body, encoding="utf-8")
            reader = csv.DictReader(text_stream)
            # DynamoDB 書き込みのためにここでリストに変換する。
            # 巨大 CSV の場合はジェネレータのまま処理する設計変更も検討できる。
            return [dict(row) for row in reader]

    finally:
        # StreamingBody を明示的にクローズしてコネクションを解放する
        body.close()


@tracer.capture_method
def _validate_and_normalize(raw: dict) -> InputPayload:
    """
    Pydantic v2 でレコードのバリデーションと正規化を行う。

    正規化内容:
      - entity_id: 前後空白のトリム
      - event_type: 前後空白のトリム
      - event_time: 前後空白のトリム、タイムゾーン変換は event_datetime() で行う
      - value: 0 未満は ValidationError（ge=0 制約）

    Args:
        raw: S3 から読み込んだ生データの dict

    Returns:
        バリデーション・正規化済みの InputPayload

    Raises:
        ValidationError: バリデーション失敗（必須フィールド欠落・型エラー・制約違反など）
    """
    return InputPayload.model_validate(raw)


@tracer.capture_method
def _put_dynamodb(table: Any, payload: InputPayload, s3_obj: S3Object) -> None:
    """
    DynamoDB に EventRecord を条件付き PutItem で書き込む。

    条件式: entity_id AND event_ts が両方存在しない場合のみ書き込む。
    これにより SQS の at-least-once 配信によるメッセージ重複処理を防ぐ（冪等性の保証）。

    ConditionalCheckFailedException（重複）は障害ではなく正常系の一部として扱う。
    重複を検知した場合は警告ログを出力してスキップし、呼び出し元に例外を伝播しない。

    Args:
        table:   boto3 DynamoDB Table リソース
        payload: バリデーション済みの InputPayload
        s3_obj:  取り込み元の S3 オブジェクト情報（トレーサビリティ用）

    Raises:
        ClientError: ConditionalCheckFailedException 以外の AWS エラー（再試行対象）
    """
    dt_utc = payload.event_datetime()

    record = EventRecord(
        entity_id=payload.entity_id,
        event_ts=make_event_sk(dt_utc),
        status=EventStatus.PENDING,
        # payload には entity_id と event_time を除いたフィールドを格納する
        # （entity_id と event_time は DynamoDB の PK/SK として別途保存されるため）
        payload=payload.model_dump(exclude={"entity_id", "event_time"}),
        expires_at=ttl_after_days(30),
        source_bucket=s3_obj.bucket,
        source_key=s3_obj.key,
        ingested_at=datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    item = to_dynamodb_compatible(record.model_dump())

    try:
        table.put_item(
            Item=item,
            # 重複防止の条件付き書き込み:
            # entity_id（PK）と event_ts（SK）の両方が存在しない場合のみ書き込む。
            # 存在する場合は ConditionalCheckFailedException が発生してスキップされる。
            ConditionExpression=(
                Attr("entity_id").not_exists() & Attr("event_ts").not_exists()
            ),
        )
        logger.debug(
            "DynamoDB 書き込み成功",
            extra={"entity_id": record.entity_id, "event_ts": record.event_ts},
        )

    except ClientError as e:
        error_code = e.response["Error"]["Code"]

        if error_code == "ConditionalCheckFailedException":
            # 重複イベント: SQS の at-least-once により同一メッセージが再配信された
            # エラーとして扱わずスキップし、後続処理を続行する
            logger.warning(
                "重複イベントのためスキップ（冪等性保証）",
                extra={
                    "entity_id": record.entity_id,
                    "event_ts": record.event_ts,
                    "source_key": s3_obj.key,
                },
            )
            return

        # その他の AWS エラー（スロットリング・ネットワーク障害など）は再試行対象として再 raise
        logger.error(
            "DynamoDB 書き込みエラー",
            extra={"error_code": error_code, "entity_id": record.entity_id},
        )
        raise


@tracer.capture_method
def _process_s3_object(table: Any, s3_obj: S3Object) -> tuple[int, int]:
    """
    S3 オブジェクト 1 件を処理し（processed_count, validation_error_count）を返す。

    ファイル内の各レコードを個別にバリデーション → DynamoDB 書き込みする。
    1 ファイル内に一部バリデーション失敗レコードがあっても、
    他のレコードは正常に処理を続ける（行単位の独立処理）。

    バリデーション失敗はログに記録してカウントし、DLQ には送らない（恒久エラーのため）。
    DynamoDB 書き込みエラーは例外として再 raise し、SQS メッセージ全体を失敗扱いにする。

    Args:
        table:  DynamoDB テーブルリソース
        s3_obj: 処理対象の S3 オブジェクト情報

    Returns:
        (処理済みレコード数, バリデーションエラーレコード数)
    """
    raw_records = _download_s3_streaming(s3_obj.bucket, s3_obj.key)

    logger.info(
        "S3 オブジェクトからレコードを読み込み",
        extra={"key": s3_obj.key, "record_count": len(raw_records)},
    )

    processed_count = 0
    validation_error_count = 0

    for raw in raw_records:
        try:
            payload = _validate_and_normalize(raw)
        except ValidationError as e:
            # バリデーション失敗: 入力データの設計上の問題（恒久エラー）
            # DLQ へ送ると延々と再試行されるため、ここでスキップして ValidationErrors にカウントする。
            # 詳細なエラー情報をログに残して調査に役立てる。
            logger.error(
                "レコードのバリデーション失敗",
                extra={
                    "record": raw,
                    "error_count": len(e.errors()),
                    "errors": e.errors(),
                    "source_key": s3_obj.key,
                },
            )
            validation_error_count += 1
            metrics.add_metric(name="ValidationErrors", unit=MetricUnit.Count, value=1)
            continue

        # DynamoDB 書き込み（ConditionalCheckFailed は内部でスキップ済み）
        _put_dynamodb(table, payload, s3_obj)
        processed_count += 1

    return processed_count, validation_error_count


def _record_handler(record: SQSRecord) -> None:
    """
    SQS レコード 1 件を処理するコールバック関数。
    BatchProcessor から呼び出される。

    例外が raise されると当該メッセージが batchItemFailures に追加され、
    SQS による再試行・最終的な DLQ 転送の対象になる。

    1 つの SQS メッセージには複数の S3 イベントが含まれる場合があるため、
    すべての S3 オブジェクトを順次処理する。

    Args:
        record: Powertools が型付けした SQS レコード
    """
    # SQS messageId をログコンテキストに追加して問題メッセージのトレースを容易にする
    logger.append_keys(sqs_message_id=record.message_id)

    start_time = time.perf_counter()
    table = _get_table()

    # SQS メッセージボディを解析して処理対象 S3 オブジェクトを取得する
    s3_objects = parse_s3_notification(record.body)

    if not s3_objects:
        # S3 テストイベントや対象外イベントは正常終了（例外なし）としてスキップ
        logger.info(
            "処理対象の S3 オブジェクトなし（テストイベントまたは ObjectCreated 以外）",
            extra={"message_id": record.message_id},
        )
        return

    total_processed = 0
    total_validation_errors = 0

    for s3_obj in s3_objects:
        logger.info(
            "S3 オブジェクト処理開始",
            extra={"bucket": s3_obj.bucket, "key": s3_obj.key, "size_bytes": s3_obj.size},
        )
        processed, validation_errors = _process_s3_object(table, s3_obj)
        total_processed += processed
        total_validation_errors += validation_errors

    # 処理レイテンシをメトリクスとして記録する（SQS メッセージ単位の処理時間）
    elapsed_ms = (time.perf_counter() - start_time) * 1000

    metrics.add_metric(
        name="ProcessedRecords",
        unit=MetricUnit.Count,
        value=total_processed,
    )
    metrics.add_metric(
        name="ProcessingLatencyMs",
        unit=MetricUnit.Milliseconds,
        value=elapsed_ms,
    )

    logger.info(
        "SQS メッセージ処理完了",
        extra={
            "processed_records": total_processed,
            "validation_errors": total_validation_errors,
            "elapsed_ms": round(elapsed_ms, 2),
            "s3_objects_count": len(s3_objects),
        },
    )


# ── Lambda ハンドラ ───────────────────────────────────────────

@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def lambda_handler(event: dict, context: LambdaContext) -> PartialItemFailureResponse:
    """
    SQS バッチイベントを受信してバッチ内の各メッセージを個別処理する。

    process_partial_response が以下を自動処理する:
      1. event["Records"] を SQSRecord リストに変換
      2. 各レコードに対して _record_handler を呼び出す
      3. _record_handler が例外を raise したレコードを batchItemFailures に追加
      4. {"batchItemFailures": [{"itemIdentifier": "<messageId>"}, ...]} を返す

    Lambda ESM の設定（Terraform sqs-pipeline モジュール）:
      - ReportBatchItemFailures: このレスポンス形式を SQS に伝える
      - bisect_batch_on_function_error: 全体クラッシュ時はバッチを分割して再試行

    X-Ray トレーシング:
      @tracer.capture_lambda_handler がリクエスト全体をセグメントとして記録する。
      _record_handler・各 S3 処理は @tracer.capture_method でサブセグメントになる。

    注意: @logger.inject_lambda_context に correlation_id_path を指定していない理由:
      SQS イベントには HTTP ヘッダーが存在しないため相関 ID パスが適用できない。
      各 SQS メッセージの messageId を _record_handler 内でログコンテキストに付与している。

    Args:
        event:   SQS イベント（{"Records": [{"messageId": ..., "body": ...}, ...]}}）
        context: Lambda コンテキスト（残り実行時間・メモリ情報など）

    Returns:
        PartialItemFailureResponse: {"batchItemFailures": [...]} 形式のレスポンス
    """
    if not event.get("Records"):
        return {"batchItemFailures": []}

    return process_partial_response(
        event=event,
        record_handler=_record_handler,
        processor=processor,
        context=context,
    )
