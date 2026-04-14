"""
ingestor Lambda のユニットテスト
外部依存なし（moto で AWS サービスをモック）。

テスト構成:
  TestDetectFormat          - detect_format: 拡張子によるフォーマット判定
  TestParseS3Notification   - parse_s3_notification: SQS ボディ解析
  TestValidateAndNormalize  - _validate_and_normalize: Pydantic バリデーション
  TestDownloadS3Streaming   - _download_s3_streaming: S3 ストリーミング読み込み
  TestPutDynamoDB           - _put_dynamodb: 条件付き書き込み・重複処理
  TestProcessS3Object       - _process_s3_object: ファイル全体処理
  TestLambdaHandler         - lambda_handler: SQS バッチ部分失敗
"""
import json
import os

import boto3
import pytest
from botocore.exceptions import ClientError
from moto import mock_aws

# モジュールインポート前に環境変数を設定する。
# Powertools は import 時に POWERTOOLS_SERVICE_NAME を参照するため、
# テストファイルのトップレベルで setdefault する必要がある。
os.environ.setdefault("EVENTS_TABLE_NAME", "sep-test-events")
os.environ.setdefault("POWERTOOLS_SERVICE_NAME", "sep-test-ingestor")
os.environ.setdefault("POWERTOOLS_METRICS_NAMESPACE", "ServerlessEventPipeline")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
# X-Ray SDK がない環境でも動作するように無効化する
os.environ.setdefault("POWERTOOLS_TRACE_DISABLED", "1")

# ── 定数 ────────────────────────────────────────────────────────
BUCKET_NAME = "sep-test-raw-123456789012"
TABLE_NAME = "sep-test-events"

# ── テストデータ ─────────────────────────────────────────────────
VALID_JSON_RECORD = {
    "entity_id": "USER#u001",
    "event_type": "purchase",
    "event_time": "2024-01-15T12:00:00Z",
    "value": 1500.0,
    "metadata": {"product_id": "p001", "category": "electronics"},
}

VALID_JSON_RECORDS = [
    {
        "entity_id": "USER#u001",
        "event_type": "purchase",
        "event_time": "2024-01-15T12:00:00Z",
        "value": 1500.0,
        "metadata": {"product_id": "p001"},
    },
    {
        "entity_id": "USER#u002",
        "event_type": "view",
        "event_time": "2024-01-15T12:05:00Z",
        "metadata": {"page_path": "/products"},
    },
]

# CSV の value 列には数値文字列を使用する。
# 空文字列 "" は Pydantic の Optional[float] で coerce に失敗するため省略しない。
VALID_CSV_CONTENT = (
    "entity_id,event_type,event_time,value\n"
    "USER#u003,view,2024-01-15T12:10:00Z,0\n"
    "USER#u004,purchase,2024-01-15T12:15:00Z,3000\n"
)


# ── ヘルパー ─────────────────────────────────────────────────────

class FakeLambdaContext:
    """Powertools の inject_lambda_context が参照するプロパティを持つ最小モック。"""
    function_name = "sep-test-ingestor"
    memory_limit_in_mb = 256
    invoked_function_arn = (
        "arn:aws:lambda:ap-northeast-1:123456789012:function:sep-test-ingestor"
    )
    aws_request_id = "test-request-id-ingestor-001"


def _make_s3_notification(bucket: str, key: str, size: int = 100) -> str:
    """S3 ObjectCreated:Put 通知の JSON 文字列を生成する。"""
    return json.dumps({
        "Records": [
            {
                "eventName": "ObjectCreated:Put",
                "s3": {
                    "bucket": {"name": bucket},
                    "object": {"key": key, "size": size},
                },
            }
        ]
    })


def _make_sqs_record(
    message_id: str,
    body: str,
) -> dict:
    """SQS レコード 1 件の辞書を生成する。"""
    return {
        "messageId": message_id,
        "receiptHandle": f"receipt-{message_id}",
        "body": body,
        "attributes": {
            "ApproximateReceiveCount": "1",
            "SentTimestamp": "1234567890000",
            "SenderId": "AIDAIENQZJOLO23YVJ4VO",
            "ApproximateFirstReceiveTimestamp": "1234567890001",
        },
        "messageAttributes": {},
        "md5OfBody": "abc123",
        "eventSource": "aws:sqs",
        "eventSourceARN": "arn:aws:sqs:ap-northeast-1:123456789012:sep-test-queue",
        "awsRegion": "ap-northeast-1",
    }


def _make_sqs_event(bucket: str, key: str, message_id: str = "msg-001", size: int = 100) -> dict:
    """S3 通知を持つ SQS バッチイベントを生成する。"""
    return {
        "Records": [
            _make_sqs_record(
                message_id=message_id,
                body=_make_s3_notification(bucket, key, size),
            )
        ]
    }


@pytest.fixture
def aws_env(aws_credentials):
    """
    S3 バケットと DynamoDB テーブルを moto で作成するフィクスチャ。

    moto v4 は botocore レベルでパッチを当てるため、
    モジュールレベルで初期化済みの boto3 クライアントも
    このコンテキスト内では moto に向かう。
    """
    with mock_aws():
        s3 = boto3.client("s3", region_name="ap-northeast-1")
        s3.create_bucket(
            Bucket=BUCKET_NAME,
            CreateBucketConfiguration={"LocationConstraint": "ap-northeast-1"},
        )

        dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")
        table = dynamodb.create_table(
            TableName=TABLE_NAME,
            KeySchema=[
                {"AttributeName": "entity_id", "KeyType": "HASH"},
                {"AttributeName": "event_ts", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "entity_id", "AttributeType": "S"},
                {"AttributeName": "event_ts", "AttributeType": "S"},
                {"AttributeName": "status", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "status-index",
                    "KeySchema": [
                        {"AttributeName": "status", "KeyType": "HASH"},
                        {"AttributeName": "event_ts", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        yield {"s3": s3, "dynamodb": dynamodb, "table": table}


# ── TestDetectFormat ─────────────────────────────────────────────

class TestDetectFormat:
    """detect_format: S3 キー拡張子によるフォーマット判定。"""

    def test_json_extension_returns_json(self):
        from ingestor.validator import detect_format
        assert detect_format("raw/2024/01/events.json") == "json"

    def test_csv_extension_returns_csv(self):
        from ingestor.validator import detect_format
        assert detect_format("raw/2024/01/events.csv") == "csv"

    def test_uppercase_extension_is_normalized(self):
        from ingestor.validator import detect_format
        assert detect_format("events.JSON") == "json"
        assert detect_format("events.CSV") == "csv"

    def test_unsupported_extension_raises_value_error(self):
        from ingestor.validator import detect_format
        with pytest.raises(ValueError, match="未対応のファイル形式"):
            detect_format("events.parquet")

    def test_no_extension_raises_value_error(self):
        from ingestor.validator import detect_format
        with pytest.raises(ValueError):
            detect_format("events_no_extension")

    def test_deeply_nested_key_with_json(self):
        """パスに複数のスラッシュが含まれても正しく判定する。"""
        from ingestor.validator import detect_format
        assert detect_format("year=2024/month=01/day=15/events.json") == "json"


# ── TestParseS3Notification ──────────────────────────────────────

class TestParseS3Notification:
    """parse_s3_notification: SQS ボディから S3 オブジェクト情報を抽出。"""

    def test_object_created_put_returns_s3_object(self):
        from ingestor.validator import parse_s3_notification
        body = _make_s3_notification("my-bucket", "events.json", 1024)
        result = parse_s3_notification(body)
        assert len(result) == 1
        assert result[0].bucket == "my-bucket"
        assert result[0].key == "events.json"
        assert result[0].size == 1024

    def test_url_encoded_key_is_decoded(self):
        """S3 オブジェクトキーの URL エンコードを解除する（スペース・スラッシュ等）。"""
        from ingestor.validator import parse_s3_notification
        body = json.dumps({
            "Records": [{
                "eventName": "ObjectCreated:Put",
                "s3": {
                    "bucket": {"name": "my-bucket"},
                    "object": {"key": "path%2Fto%2Fevents%20data.json", "size": 100},
                },
            }]
        })
        result = parse_s3_notification(body)
        assert result[0].key == "path/to/events data.json"

    def test_s3_test_event_returns_empty_list(self):
        """バケット通知設定時の S3 テストイベントはスキップされる。"""
        from ingestor.validator import parse_s3_notification
        body = json.dumps({"Event": "s3:TestEvent"})
        assert parse_s3_notification(body) == []

    def test_object_removed_event_is_skipped(self):
        """ObjectRemoved 系イベントは処理対象外。"""
        from ingestor.validator import parse_s3_notification
        body = json.dumps({
            "Records": [{
                "eventName": "ObjectRemoved:Delete",
                "s3": {
                    "bucket": {"name": "my-bucket"},
                    "object": {"key": "events.json", "size": 0},
                },
            }]
        })
        assert parse_s3_notification(body) == []

    def test_multiple_records_returns_multiple_s3_objects(self):
        """S3 通知に複数レコードが含まれる場合、すべて返す。"""
        from ingestor.validator import parse_s3_notification
        body = json.dumps({
            "Records": [
                {
                    "eventName": "ObjectCreated:Put",
                    "s3": {
                        "bucket": {"name": "bucket-a"},
                        "object": {"key": "file1.json", "size": 100},
                    },
                },
                {
                    "eventName": "ObjectCreated:CompleteMultipartUpload",
                    "s3": {
                        "bucket": {"name": "bucket-a"},
                        "object": {"key": "file2.csv", "size": 200},
                    },
                },
            ]
        })
        result = parse_s3_notification(body)
        assert len(result) == 2
        assert result[0].key == "file1.json"
        assert result[1].key == "file2.csv"

    def test_invalid_json_raises_value_error(self):
        from ingestor.validator import parse_s3_notification
        with pytest.raises(ValueError, match="有効な JSON"):
            parse_s3_notification("not-json{{{")

    def test_empty_records_list_returns_empty(self):
        from ingestor.validator import parse_s3_notification
        assert parse_s3_notification(json.dumps({"Records": []})) == []

    def test_mixed_events_only_returns_object_created(self):
        """ObjectCreated と ObjectRemoved が混在する場合、ObjectCreated のみ返す。"""
        from ingestor.validator import parse_s3_notification
        body = json.dumps({
            "Records": [
                {
                    "eventName": "ObjectCreated:Put",
                    "s3": {
                        "bucket": {"name": "b"},
                        "object": {"key": "new.json", "size": 50},
                    },
                },
                {
                    "eventName": "ObjectRemoved:Delete",
                    "s3": {
                        "bucket": {"name": "b"},
                        "object": {"key": "old.json", "size": 0},
                    },
                },
            ]
        })
        result = parse_s3_notification(body)
        assert len(result) == 1
        assert result[0].key == "new.json"


# ── TestValidateAndNormalize ─────────────────────────────────────

class TestValidateAndNormalize:
    """_validate_and_normalize: Pydantic v2 によるバリデーション・正規化。"""

    def test_valid_record_returns_input_payload(self):
        from ingestor.handler import _validate_and_normalize
        result = _validate_and_normalize(VALID_JSON_RECORD.copy())
        assert result.entity_id == "USER#u001"
        assert result.event_type == "purchase"
        assert result.value == 1500.0
        assert result.metadata == {"product_id": "p001", "category": "electronics"}

    def test_missing_entity_id_raises_validation_error(self):
        from pydantic import ValidationError
        from ingestor.handler import _validate_and_normalize
        raw = {k: v for k, v in VALID_JSON_RECORD.items() if k != "entity_id"}
        with pytest.raises(ValidationError):
            _validate_and_normalize(raw)

    def test_missing_event_type_raises_validation_error(self):
        from pydantic import ValidationError
        from ingestor.handler import _validate_and_normalize
        raw = {k: v for k, v in VALID_JSON_RECORD.items() if k != "event_type"}
        with pytest.raises(ValidationError):
            _validate_and_normalize(raw)

    def test_missing_event_time_raises_validation_error(self):
        from pydantic import ValidationError
        from ingestor.handler import _validate_and_normalize
        raw = {k: v for k, v in VALID_JSON_RECORD.items() if k != "event_time"}
        with pytest.raises(ValidationError):
            _validate_and_normalize(raw)

    def test_invalid_entity_id_format_raises_validation_error(self):
        """entity_id が '<TYPE>#<ID>' 形式でない場合は ValidationError。"""
        from pydantic import ValidationError
        from ingestor.handler import _validate_and_normalize
        raw = {**VALID_JSON_RECORD, "entity_id": "INVALID_NO_HASH_SIGN"}
        with pytest.raises(ValidationError):
            _validate_and_normalize(raw)

    def test_entity_id_with_empty_parts_raises_validation_error(self):
        """entity_id の TYPE または ID 部分が空文字は不正。"""
        from pydantic import ValidationError
        from ingestor.handler import _validate_and_normalize
        for bad_id in ["#id_only", "TYPE#", "#"]:
            with pytest.raises(ValidationError):
                _validate_and_normalize({**VALID_JSON_RECORD, "entity_id": bad_id})

    def test_invalid_event_time_format_raises_validation_error(self):
        """ISO 8601 形式でない event_time は ValidationError。"""
        from pydantic import ValidationError
        from ingestor.handler import _validate_and_normalize
        raw = {**VALID_JSON_RECORD, "event_time": "2024/01/15 12:00:00"}
        with pytest.raises(ValidationError):
            _validate_and_normalize(raw)

    def test_negative_value_raises_validation_error(self):
        """value が 0 未満は ge=0 制約違反で ValidationError。"""
        from pydantic import ValidationError
        from ingestor.handler import _validate_and_normalize
        raw = {**VALID_JSON_RECORD, "value": -100}
        with pytest.raises(ValidationError):
            _validate_and_normalize(raw)

    def test_whitespace_is_stripped_from_string_fields(self):
        """entity_id と event_type の前後空白がトリムされる。"""
        from ingestor.handler import _validate_and_normalize
        raw = {
            **VALID_JSON_RECORD,
            "entity_id": "  USER#u001  ",
            "event_type": "  purchase  ",
        }
        result = _validate_and_normalize(raw)
        assert result.entity_id == "USER#u001"
        assert result.event_type == "purchase"

    def test_optional_value_defaults_to_none(self):
        """value フィールドは省略可能（None でも合格）。"""
        from ingestor.handler import _validate_and_normalize
        raw = {k: v for k, v in VALID_JSON_RECORD.items() if k != "value"}
        result = _validate_and_normalize(raw)
        assert result.value is None

    def test_optional_metadata_defaults_to_empty_dict(self):
        """metadata フィールドは省略可能（デフォルトは空辞書）。"""
        from ingestor.handler import _validate_and_normalize
        raw = {k: v for k, v in VALID_JSON_RECORD.items() if k != "metadata"}
        result = _validate_and_normalize(raw)
        assert result.metadata == {}

    def test_event_datetime_returns_utc_datetime(self):
        """event_datetime() が UTC タイムゾーン付き datetime を返す。"""
        from datetime import timezone
        from ingestor.handler import _validate_and_normalize
        result = _validate_and_normalize(VALID_JSON_RECORD.copy())
        dt = result.event_datetime()
        assert dt.tzinfo == timezone.utc
        assert dt.year == 2024
        assert dt.month == 1
        assert dt.day == 15


# ── TestDownloadS3Streaming ──────────────────────────────────────

class TestDownloadS3Streaming:
    """_download_s3_streaming: S3 からのストリーミング読み込み。"""

    def test_json_array_returns_list_of_records(self, aws_env):
        from ingestor.handler import _download_s3_streaming
        key = "raw/events.json"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME,
            Key=key,
            Body=json.dumps(VALID_JSON_RECORDS).encode("utf-8"),
        )
        result = _download_s3_streaming(BUCKET_NAME, key)
        assert len(result) == 2
        assert result[0]["entity_id"] == "USER#u001"
        assert result[1]["entity_id"] == "USER#u002"

    def test_single_json_object_is_wrapped_in_list(self, aws_env):
        """トップレベルが dict の JSON は 1 要素リストとして返す。"""
        from ingestor.handler import _download_s3_streaming
        key = "raw/single.json"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME,
            Key=key,
            Body=json.dumps(VALID_JSON_RECORD).encode("utf-8"),
        )
        result = _download_s3_streaming(BUCKET_NAME, key)
        assert len(result) == 1
        assert result[0]["entity_id"] == "USER#u001"

    def test_csv_file_returns_list_of_dicts_with_header_as_keys(self, aws_env):
        from ingestor.handler import _download_s3_streaming
        key = "raw/events.csv"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME,
            Key=key,
            Body=VALID_CSV_CONTENT.encode("utf-8"),
        )
        result = _download_s3_streaming(BUCKET_NAME, key)
        assert len(result) == 2
        assert result[0]["entity_id"] == "USER#u003"
        assert result[0]["event_type"] == "view"
        assert result[1]["entity_id"] == "USER#u004"
        assert result[1]["value"] == "3000"  # CSV は文字列、Pydantic が後で変換する

    def test_unsupported_extension_raises_value_error(self, aws_env):
        from ingestor.handler import _download_s3_streaming
        with pytest.raises(ValueError, match="未対応のファイル形式"):
            _download_s3_streaming(BUCKET_NAME, "events.parquet")


# ── TestPutDynamoDB ──────────────────────────────────────────────

class TestPutDynamoDB:
    """_put_dynamodb: 条件付き書き込み・重複処理・エラーハンドリング。"""

    def test_valid_record_is_written_to_dynamodb(self, aws_env):
        """バリデーション済みレコードが DynamoDB に正常書き込みされる。"""
        from ingestor.handler import _put_dynamodb, _validate_and_normalize
        from ingestor.validator import S3Object

        payload = _validate_and_normalize(VALID_JSON_RECORD.copy())
        s3_obj = S3Object(bucket=BUCKET_NAME, key="raw/events.json", size=100)
        _put_dynamodb(aws_env["table"], payload, s3_obj)

        items = aws_env["table"].scan()["Items"]
        assert len(items) == 1
        assert items[0]["entity_id"] == "USER#u001"
        assert items[0]["status"] == "PENDING"
        assert items[0]["source_bucket"] == BUCKET_NAME
        assert items[0]["source_key"] == "raw/events.json"
        assert "event_ts" in items[0]
        assert "expires_at" in items[0]
        assert "ingested_at" in items[0]

    def test_duplicate_record_is_skipped_without_exception(self, aws_env):
        """
        同一 entity_id + event_ts の重複書き込みは ConditionalCheckFailedException を
        内部で吸収し、呼び出し元に例外を伝播しない（冪等性の保証）。
        """
        from ingestor.handler import _put_dynamodb, _validate_and_normalize
        from ingestor.validator import S3Object

        payload = _validate_and_normalize(VALID_JSON_RECORD.copy())
        s3_obj = S3Object(bucket=BUCKET_NAME, key="raw/events.json", size=100)

        _put_dynamodb(aws_env["table"], payload, s3_obj)
        # 2 回目: 例外が raise されず正常終了することを確認
        _put_dynamodb(aws_env["table"], payload, s3_obj)

        # DynamoDB にはレコードが 1 件のみ存在する
        assert aws_env["table"].scan()["Count"] == 1

    def test_different_event_times_create_separate_records(self, aws_env):
        """同一 entity_id でも event_ts が異なれば別レコードとして書き込まれる。"""
        from ingestor.handler import _put_dynamodb, _validate_and_normalize
        from ingestor.validator import S3Object

        s3_obj = S3Object(bucket=BUCKET_NAME, key="raw/events.json", size=100)
        raw1 = {**VALID_JSON_RECORD, "event_time": "2024-01-15T12:00:00Z"}
        raw2 = {**VALID_JSON_RECORD, "event_time": "2024-01-15T13:00:00Z"}

        _put_dynamodb(aws_env["table"], _validate_and_normalize(raw1), s3_obj)
        _put_dynamodb(aws_env["table"], _validate_and_normalize(raw2), s3_obj)

        assert aws_env["table"].scan()["Count"] == 2

    def test_non_conditional_client_error_is_reraised(self, aws_env):
        """ConditionalCheckFailedException 以外の ClientError は再 raise される。"""
        from unittest.mock import MagicMock
        from ingestor.handler import _put_dynamodb, _validate_and_normalize
        from ingestor.validator import S3Object

        payload = _validate_and_normalize(VALID_JSON_RECORD.copy())
        s3_obj = S3Object(bucket=BUCKET_NAME, key="raw/events.json", size=100)

        error_response = {
            "Error": {
                "Code": "ProvisionedThroughputExceededException",
                "Message": "Request rate is too high",
            }
        }
        mock_table = MagicMock()
        mock_table.put_item.side_effect = ClientError(error_response, "PutItem")

        with pytest.raises(ClientError) as exc_info:
            _put_dynamodb(mock_table, payload, s3_obj)

        assert exc_info.value.response["Error"]["Code"] == "ProvisionedThroughputExceededException"


# ── TestProcessS3Object ──────────────────────────────────────────

class TestProcessS3Object:
    """_process_s3_object: S3 オブジェクト単体の処理フロー（DL → validate → DDB）。"""

    def test_json_file_processes_all_valid_records(self, aws_env):
        from ingestor.handler import _process_s3_object
        from ingestor.validator import S3Object

        key = "raw/events.json"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME, Key=key,
            Body=json.dumps(VALID_JSON_RECORDS).encode("utf-8"),
        )

        processed, errors = _process_s3_object(
            aws_env["table"], S3Object(bucket=BUCKET_NAME, key=key, size=200)
        )

        assert processed == 2
        assert errors == 0
        assert aws_env["table"].scan()["Count"] == 2

    def test_csv_file_processes_all_valid_records(self, aws_env):
        from ingestor.handler import _process_s3_object
        from ingestor.validator import S3Object

        key = "raw/events.csv"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME, Key=key,
            Body=VALID_CSV_CONTENT.encode("utf-8"),
        )

        processed, errors = _process_s3_object(
            aws_env["table"], S3Object(bucket=BUCKET_NAME, key=key, size=100)
        )

        assert processed == 2
        assert errors == 0

    def test_validation_errors_are_counted_and_processing_continues(self, aws_env):
        """
        バリデーション失敗レコードは ValidationErrors にカウントされる。
        バッチ全体は失敗せず、正常レコードは DynamoDB に書き込まれる。
        """
        from ingestor.handler import _process_s3_object
        from ingestor.validator import S3Object

        records = [
            VALID_JSON_RECORDS[0],  # 正常
            {
                "entity_id": "INVALID_NO_HASH",
                "event_type": "purchase",
                "event_time": "2024-01-15T12:00:00Z",
            },  # entity_id 形式不正
            {
                "entity_id": "USER#u999",
                "event_type": "view",
                "event_time": "not-a-date",
            },  # event_time 形式不正
        ]
        key = "raw/mixed.json"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME, Key=key,
            Body=json.dumps(records).encode("utf-8"),
        )

        processed, errors = _process_s3_object(
            aws_env["table"], S3Object(bucket=BUCKET_NAME, key=key, size=300)
        )

        assert processed == 1
        assert errors == 2
        # 正常な 1 件のみ DynamoDB に書き込まれている
        assert aws_env["table"].scan()["Count"] == 1

    def test_all_invalid_records_yields_zero_processed(self, aws_env):
        """全レコードがバリデーション失敗の場合 processed=0、errors=全件。"""
        from ingestor.handler import _process_s3_object
        from ingestor.validator import S3Object

        records = [
            {"entity_id": "NO_HASH", "event_type": "x", "event_time": "bad"},
            {"entity_id": "NO_HASH_2", "event_type": "y", "event_time": "bad"},
        ]
        key = "raw/all_invalid.json"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME, Key=key,
            Body=json.dumps(records).encode("utf-8"),
        )

        processed, errors = _process_s3_object(
            aws_env["table"], S3Object(bucket=BUCKET_NAME, key=key, size=100)
        )

        assert processed == 0
        assert errors == 2
        assert aws_env["table"].scan()["Count"] == 0


# ── TestLambdaHandler ────────────────────────────────────────────

class TestLambdaHandler:
    """lambda_handler: SQS バッチ全体の処理・部分失敗レスポンス。"""

    def test_successful_batch_returns_empty_batch_item_failures(self, aws_env):
        """正常バッチは batchItemFailures が空のレスポンスを返す。"""
        from ingestor.handler import lambda_handler

        key = "raw/success.json"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME, Key=key,
            Body=json.dumps(VALID_JSON_RECORDS).encode("utf-8"),
        )

        event = _make_sqs_event(BUCKET_NAME, key, message_id="msg-success-001")
        response = lambda_handler(event, FakeLambdaContext())

        assert response["batchItemFailures"] == []
        assert aws_env["table"].scan()["Count"] == 2

    def test_s3_test_event_is_skipped_successfully(self, aws_env):
        """S3 テストイベントは例外なしでスキップされ batchItemFailures に追加されない。"""
        from ingestor.handler import lambda_handler

        event = {
            "Records": [
                _make_sqs_record(
                    message_id="msg-test-event-001",
                    body=json.dumps({"Event": "s3:TestEvent"}),
                )
            ]
        }
        response = lambda_handler(event, FakeLambdaContext())
        assert response["batchItemFailures"] == []

    def test_partial_failure_returns_correct_item_identifier(self, aws_env):
        """
        バッチ内の 1 メッセージが S3 NoSuchKey で失敗した場合、
        失敗した messageId のみが batchItemFailures に含まれる。
        正常メッセージは DynamoDB に書き込まれる。
        """
        from ingestor.handler import lambda_handler

        good_key = "raw/good.json"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME, Key=good_key,
            Body=json.dumps([VALID_JSON_RECORDS[0]]).encode("utf-8"),
        )
        bad_key = "raw/does_not_exist.json"  # S3 に存在しない

        event = {
            "Records": [
                _make_sqs_record(
                    message_id="msg-good-001",
                    body=_make_s3_notification(BUCKET_NAME, good_key, 100),
                ),
                _make_sqs_record(
                    message_id="msg-bad-002",
                    body=_make_s3_notification(BUCKET_NAME, bad_key, 0),
                ),
            ]
        }

        response = lambda_handler(event, FakeLambdaContext())

        failed_ids = {item["itemIdentifier"] for item in response["batchItemFailures"]}
        # 存在しない S3 キーを持つメッセージは失敗する
        assert "msg-bad-002" in failed_ids
        # 正常メッセージは失敗リストに含まれない
        assert "msg-good-001" not in failed_ids
        # 正常メッセージのレコードは DynamoDB に書き込まれている
        assert aws_env["table"].scan()["Count"] == 1

    def test_empty_records_returns_no_failures(self, aws_env):
        """Records が空のバッチは例外なく処理される。"""
        from ingestor.handler import lambda_handler
        response = lambda_handler({"Records": []}, FakeLambdaContext())
        assert response["batchItemFailures"] == []

    def test_duplicate_sqs_message_is_idempotent(self, aws_env):
        """
        同一 S3 ファイルを指す SQS メッセージが 2 回処理されても、
        DynamoDB には重複レコードが書き込まれない（冪等性）。
        """
        from ingestor.handler import lambda_handler

        key = "raw/idempotent.json"
        aws_env["s3"].put_object(
            Bucket=BUCKET_NAME, Key=key,
            Body=json.dumps([VALID_JSON_RECORDS[0]]).encode("utf-8"),
        )

        event = _make_sqs_event(BUCKET_NAME, key, message_id="msg-dup-001")
        lambda_handler(event, FakeLambdaContext())
        lambda_handler(event, FakeLambdaContext())  # 再処理

        # 重複書き込みなし: レコードは 1 件のみ
        assert aws_env["table"].scan()["Count"] == 1
