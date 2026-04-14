"""
transformer Lambda のユニットテスト
外部依存なし（純粋関数）または moto で DynamoDB をモック。

テスト構成:
  TestValidateSchema        - _validate_schema: 必須フィールド・型チェック
  TestNormalizeEntityId     - _normalize_entity_id: TYPE 大文字化
  TestBuildSortKey          - _build_sort_key: DynamoDB SK フォーマット
  TestTransformPurchase     - PURCHASE イベントの変換・revenue_tier
  TestTransformView         - VIEW イベントの変換・duration クランプ
  TestTransformClick        - CLICK イベントの変換・座標変換
  TestTransformRecord       - transform_record: エンドツーエンドの変換検証
  TestRecordHandler         - record_handler: Kinesis レコードの base64 デコード
  TestWriteChunkWithRetry   - _write_chunk_with_retry: UnprocessedItems 再試行
  TestLambdaHandler         - lambda_handler: Kinesis バッチ全体のフロー
"""
import base64
import json
import os
import time
from datetime import datetime, timezone
from decimal import Decimal
from unittest.mock import MagicMock, call, patch

import boto3
import pytest
from moto import mock_aws

# Powertools・transformer モジュールのインポート前に環境変数を設定する
os.environ.setdefault("EVENTS_TABLE_NAME", "sep-test-events")
os.environ.setdefault("POWERTOOLS_SERVICE_NAME", "sep-test-transformer")
os.environ.setdefault("POWERTOOLS_METRICS_NAMESPACE", "ServerlessEventPipeline")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
os.environ.setdefault("POWERTOOLS_TRACE_DISABLED", "1")

# ── テストデータ ─────────────────────────────────────────────────

BASE_RAW_DATA = {
    "entity_id": "USER#u001",
    "event_type": "PURCHASE",
    "event_time": "2024-01-15T12:00:00Z",
    "value": 1500.0,
    "metadata": {"product_id": "p001", "category": "electronics", "currency": "USD"},
}

TABLE_NAME = "sep-test-events"


# ── ヘルパー ─────────────────────────────────────────────────────

class FakeLambdaContext:
    function_name = "sep-test-transformer"
    memory_limit_in_mb = 256
    invoked_function_arn = (
        "arn:aws:lambda:ap-northeast-1:123456789012:function:sep-test-transformer"
    )
    aws_request_id = "test-request-id-transformer-001"


class FakeKinesisStreamRecord:
    """
    Powertools KinesisStreamRecord の最小モック。

    record.data は Powertools が base64 デコード済みの文字列を提供する。
    record.kinesis.approximate_arrival_timestamp は UTC datetime を返す。
    """

    class _Kinesis:
        sequence_number = "49590338271490256608559692540925702759324205998859514898"
        approximate_arrival_timestamp = datetime(2024, 1, 15, 12, 0, 0, tzinfo=timezone.utc)

    def __init__(self, raw_data: dict):
        # Powertools は base64 デコード済みの文字列を record.data に格納する
        self.data = json.dumps(raw_data)
        self.kinesis = self._Kinesis()


def _make_kinesis_event(records: list[dict]) -> dict:
    """
    Kinesis Data Streams Lambda イベントを生成する。

    Kinesis の data フィールドは base64 エンコードされた JSON 文字列。
    Lambda ESM が配信する際のフォーマットに準拠する。
    """
    kinesis_records = []
    for i, raw in enumerate(records):
        encoded = base64.b64encode(json.dumps(raw).encode("utf-8")).decode("utf-8")
        kinesis_records.append({
            "kinesis": {
                "kinesisSchemaVersion": "1.0",
                "partitionKey": "1",
                "sequenceNumber": f"4959033827149025660855969254092570275932420{i:04d}",
                "data": encoded,
                "approximateArrivalTimestamp": 1705320000.0,
            },
            "eventSource": "aws:kinesis",
            "eventVersion": "1.0",
            "eventID": f"shardId-000000000000:{i:020d}",
            "eventName": "aws:kinesis:record",
            "invokeIdentityArn": "arn:aws:iam::123456789012:role/sep-test-transformer-role",
            "awsRegion": "ap-northeast-1",
            "eventSourceARN": "arn:aws:kinesis:ap-northeast-1:123456789012:stream/sep-test-events-stream",
        })
    return {"Records": kinesis_records}


@pytest.fixture
def dynamodb_table(aws_credentials):
    """DynamoDB テーブルを moto で作成するフィクスチャ。"""
    with mock_aws():
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
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        yield table


# ── TestValidateSchema ───────────────────────────────────────────

class TestValidateSchema:
    """_validate_schema: 必須フィールド・entity_id 形式・イベントタイプ検証。"""

    def test_valid_data_passes_without_exception(self):
        from transformer.transform import _validate_schema
        _validate_schema(BASE_RAW_DATA.copy())  # 例外なし

    def test_missing_entity_id_raises_transform_error(self):
        from transformer.transform import _validate_schema, TransformError
        raw = {k: v for k, v in BASE_RAW_DATA.items() if k != "entity_id"}
        with pytest.raises(TransformError, match="必須フィールド"):
            _validate_schema(raw)

    def test_missing_event_type_raises_transform_error(self):
        from transformer.transform import _validate_schema, TransformError
        raw = {k: v for k, v in BASE_RAW_DATA.items() if k != "event_type"}
        with pytest.raises(TransformError, match="必須フィールド"):
            _validate_schema(raw)

    def test_missing_event_time_raises_transform_error(self):
        from transformer.transform import _validate_schema, TransformError
        raw = {k: v for k, v in BASE_RAW_DATA.items() if k != "event_time"}
        with pytest.raises(TransformError, match="必須フィールド"):
            _validate_schema(raw)

    def test_none_values_treated_as_missing(self):
        from transformer.transform import _validate_schema, TransformError
        raw = {**BASE_RAW_DATA, "entity_id": None}
        with pytest.raises(TransformError, match="必須フィールド"):
            _validate_schema(raw)

    def test_invalid_entity_id_format_raises_transform_error(self):
        """entity_id に '#' が含まれない場合は TransformError。"""
        from transformer.transform import _validate_schema, TransformError
        raw = {**BASE_RAW_DATA, "entity_id": "INVALID_NO_HASH"}
        with pytest.raises(TransformError, match="entity_id"):
            _validate_schema(raw)

    def test_entity_id_with_empty_parts_raises_transform_error(self):
        from transformer.transform import _validate_schema, TransformError
        for bad_id in ["#only_id", "TYPE_ONLY#", "  #  "]:
            with pytest.raises(TransformError):
                _validate_schema({**BASE_RAW_DATA, "entity_id": bad_id})

    def test_unsupported_event_type_raises_transform_error(self):
        from transformer.transform import _validate_schema, TransformError
        raw = {**BASE_RAW_DATA, "event_type": "UNKNOWN_EVENT"}
        with pytest.raises(TransformError, match="未対応のイベントタイプ"):
            _validate_schema(raw)

    def test_event_type_is_case_insensitive(self):
        """event_type は大文字・小文字どちらでも受け付ける。"""
        from transformer.transform import _validate_schema
        for event_type in ["purchase", "Purchase", "PURCHASE"]:
            _validate_schema({**BASE_RAW_DATA, "event_type": event_type})


# ── TestNormalizeEntityId ────────────────────────────────────────

class TestNormalizeEntityId:
    """_normalize_entity_id: TYPE を大文字化・前後空白トリム。"""

    def test_type_part_is_uppercased(self):
        from transformer.transform import _normalize_entity_id
        assert _normalize_entity_id("user#u001") == "USER#u001"

    def test_id_part_case_is_preserved(self):
        """ID 部分の大文字小文字は変更しない（大文字小文字区別）。"""
        from transformer.transform import _normalize_entity_id
        assert _normalize_entity_id("User#MixedCaseID") == "USER#MixedCaseID"

    def test_whitespace_in_both_parts_is_stripped(self):
        from transformer.transform import _normalize_entity_id
        assert _normalize_entity_id("  user  #  u001  ") == "USER#u001"

    def test_already_normalized_is_unchanged(self):
        from transformer.transform import _normalize_entity_id
        assert _normalize_entity_id("USER#u001") == "USER#u001"

    def test_product_entity_type(self):
        from transformer.transform import _normalize_entity_id
        assert _normalize_entity_id("product#p001") == "PRODUCT#p001"


# ── TestBuildSortKey ─────────────────────────────────────────────

class TestBuildSortKey:
    """_build_sort_key: DynamoDB SK の 'EVENT#<timestamp>' フォーマット。"""

    def test_sort_key_has_event_prefix(self):
        from transformer.transform import _build_sort_key
        sk = _build_sort_key("2024-01-15T12:00:00Z")
        assert sk == "EVENT#2024-01-15T12:00:00Z"

    def test_whitespace_in_event_time_is_stripped(self):
        from transformer.transform import _build_sort_key
        sk = _build_sort_key("  2024-01-15T12:00:00Z  ")
        assert sk == "EVENT#2024-01-15T12:00:00Z"


# ── TestTransformPurchase ────────────────────────────────────────

class TestTransformPurchase:
    """PURCHASE イベントの変換ロジック。"""

    def _make_purchase(self, value, currency="JPY", product_id=None, category=None):
        metadata = {"currency": currency}
        if product_id:
            metadata["product_id"] = product_id
        if category:
            metadata["category"] = category
        return {
            "entity_id": "USER#u001",
            "event_type": "PURCHASE",
            "event_time": "2024-01-15T12:00:00Z",
            "value": value,
            "metadata": metadata,
        }

    def test_low_revenue_tier(self):
        """value < 1000 は revenue_tier = LOW。"""
        from transformer.transform import _transform_purchase
        result = _transform_purchase(self._make_purchase(500))
        assert result["revenue_tier"] == "LOW"
        assert result["value"] == 500.0

    def test_medium_revenue_tier(self):
        """1000 <= value < 10000 は revenue_tier = MEDIUM。"""
        from transformer.transform import _transform_purchase
        result = _transform_purchase(self._make_purchase(5000))
        assert result["revenue_tier"] == "MEDIUM"

    def test_high_revenue_tier(self):
        """value >= 10000 は revenue_tier = HIGH。"""
        from transformer.transform import _transform_purchase
        result = _transform_purchase(self._make_purchase(15000))
        assert result["revenue_tier"] == "HIGH"

    def test_boundary_value_1000_is_medium(self):
        from transformer.transform import _transform_purchase
        result = _transform_purchase(self._make_purchase(1000))
        assert result["revenue_tier"] == "MEDIUM"

    def test_boundary_value_10000_is_high(self):
        from transformer.transform import _transform_purchase
        result = _transform_purchase(self._make_purchase(10000))
        assert result["revenue_tier"] == "HIGH"

    def test_currency_from_metadata(self):
        from transformer.transform import _transform_purchase
        result = _transform_purchase(self._make_purchase(1000, currency="USD"))
        assert result["currency"] == "USD"

    def test_default_currency_is_jpy(self):
        """metadata に currency がない場合は JPY をデフォルトとする。"""
        from transformer.transform import _transform_purchase
        raw = {
            "entity_id": "USER#u001",
            "event_type": "PURCHASE",
            "event_time": "2024-01-15T12:00:00Z",
            "value": 1000,
            "metadata": {},
        }
        result = _transform_purchase(raw)
        assert result["currency"] == "JPY"

    def test_missing_value_raises_transform_error(self):
        from transformer.transform import _transform_purchase, TransformError
        raw = {k: v for k, v in self._make_purchase(1000).items() if k != "value"}
        with pytest.raises(TransformError, match="value"):
            _transform_purchase(raw)

    def test_negative_value_raises_transform_error(self):
        from transformer.transform import _transform_purchase, TransformError
        with pytest.raises(TransformError, match="0 以上"):
            _transform_purchase(self._make_purchase(-100))

    def test_non_numeric_value_raises_transform_error(self):
        from transformer.transform import _transform_purchase, TransformError
        with pytest.raises(TransformError, match="数値"):
            _transform_purchase(self._make_purchase("not_a_number"))

    def test_string_numeric_value_is_coerced(self):
        """文字列の数値（CSV 由来）は float に変換される。"""
        from transformer.transform import _transform_purchase
        result = _transform_purchase(self._make_purchase("3000"))
        assert result["value"] == 3000.0

    def test_product_id_and_category_in_result(self):
        from transformer.transform import _transform_purchase
        result = _transform_purchase(
            self._make_purchase(1000, product_id="p001", category="electronics")
        )
        assert result["product_id"] == "p001"
        assert result["category"] == "electronics"

    def test_event_type_in_result_is_purchase(self):
        from transformer.transform import _transform_purchase
        result = _transform_purchase(self._make_purchase(1000))
        assert result["event_type"] == "PURCHASE"


# ── TestTransformView ────────────────────────────────────────────

class TestTransformView:
    """VIEW イベントの変換ロジック。"""

    def _make_view(self, **metadata_kwargs):
        return {
            "entity_id": "USER#u001",
            "event_type": "VIEW",
            "event_time": "2024-01-15T12:00:00Z",
            "metadata": metadata_kwargs,
        }

    def test_page_path_from_metadata(self):
        from transformer.transform import _transform_view
        result = _transform_view(self._make_view(page_path="/products/p001"))
        assert result["page_path"] == "/products/p001"

    def test_default_page_path_is_root(self):
        """metadata に page_path がない場合は '/' をデフォルトとする。"""
        from transformer.transform import _transform_view
        result = _transform_view(self._make_view())
        assert result["page_path"] == "/"

    def test_duration_seconds_is_included(self):
        from transformer.transform import _transform_view
        result = _transform_view(self._make_view(duration_seconds=45.5))
        assert result["duration_seconds"] == 45.5

    def test_negative_duration_is_clamped_to_zero(self):
        """負の duration_seconds はデータ品質問題として 0 にクランプする。"""
        from transformer.transform import _transform_view
        result = _transform_view(self._make_view(duration_seconds=-10))
        assert result["duration_seconds"] == 0.0

    def test_invalid_duration_is_set_to_none(self):
        from transformer.transform import _transform_view
        result = _transform_view(self._make_view(duration_seconds="not_a_number"))
        assert result["duration_seconds"] is None

    def test_referrer_and_user_agent_are_included(self):
        from transformer.transform import _transform_view
        result = _transform_view(
            self._make_view(referrer="https://example.com", user_agent="Mozilla/5.0")
        )
        assert result["referrer"] == "https://example.com"
        assert result["user_agent"] == "Mozilla/5.0"

    def test_event_type_in_result_is_view(self):
        from transformer.transform import _transform_view
        result = _transform_view(self._make_view())
        assert result["event_type"] == "VIEW"


# ── TestTransformClick ───────────────────────────────────────────

class TestTransformClick:
    """CLICK イベントの変換ロジック。"""

    def _make_click(self, **metadata_kwargs):
        return {
            "entity_id": "USER#u001",
            "event_type": "CLICK",
            "event_time": "2024-01-15T12:00:00Z",
            "metadata": metadata_kwargs,
        }

    def test_element_id_from_metadata(self):
        from transformer.transform import _transform_click
        result = _transform_click(self._make_click(element_id="btn-buy"))
        assert result["element_id"] == "btn-buy"

    def test_default_element_id_is_unknown(self):
        from transformer.transform import _transform_click
        result = _transform_click(self._make_click())
        assert result["element_id"] == "unknown"

    def test_click_coordinates_are_converted_to_int(self):
        """クリック座標は float → int に変換される（フロントエンドが float で送る場合を想定）。"""
        from transformer.transform import _transform_click
        result = _transform_click(self._make_click(click_x=123.7, click_y=456.2))
        assert result["click_x"] == 123
        assert result["click_y"] == 456

    def test_string_coordinates_are_converted_to_int(self):
        from transformer.transform import _transform_click
        result = _transform_click(self._make_click(click_x="200", click_y="300"))
        assert result["click_x"] == 200
        assert result["click_y"] == 300

    def test_invalid_coordinates_become_none(self):
        from transformer.transform import _transform_click
        result = _transform_click(self._make_click(click_x="bad", click_y="bad"))
        assert result["click_x"] is None
        assert result["click_y"] is None

    def test_missing_coordinates_are_none(self):
        from transformer.transform import _transform_click
        result = _transform_click(self._make_click())
        assert result["click_x"] is None
        assert result["click_y"] is None

    def test_page_path_and_target_url_in_result(self):
        from transformer.transform import _transform_click
        result = _transform_click(
            self._make_click(page_path="/home", target_url="https://example.com/buy")
        )
        assert result["page_path"] == "/home"
        assert result["target_url"] == "https://example.com/buy"

    def test_event_type_in_result_is_click(self):
        from transformer.transform import _transform_click
        result = _transform_click(self._make_click())
        assert result["event_type"] == "CLICK"


# ── TestTransformRecord ──────────────────────────────────────────

class TestTransformRecord:
    """transform_record: パブリック API の全ステップ統合テスト。"""

    def test_purchase_record_has_required_dynamodb_fields(self):
        """transform_record の結果は DynamoDB アイテムに必要なフィールドをすべて持つ。"""
        from transformer.transform import transform_record
        result = transform_record(BASE_RAW_DATA.copy())

        assert result["entity_id"] == "USER#u001"  # 正規化済み
        assert result["event_ts"].startswith("EVENT#")
        assert result["status"] == "PENDING"
        assert result["event_type"] == "PURCHASE"
        assert "payload" in result
        assert "transformed_at" in result
        assert "expires_at" in result
        assert isinstance(result["expires_at"], int)

    def test_entity_id_type_is_uppercased(self):
        """entity_id の TYPE 部分が大文字化される。"""
        from transformer.transform import transform_record
        raw = {**BASE_RAW_DATA, "entity_id": "user#u001", "event_type": "purchase"}
        result = transform_record(raw)
        assert result["entity_id"] == "USER#u001"

    def test_event_type_is_normalized_to_uppercase(self):
        from transformer.transform import transform_record
        raw = {**BASE_RAW_DATA, "event_type": "purchase"}
        result = transform_record(raw)
        assert result["event_type"] == "PURCHASE"

    def test_view_record_returns_view_payload(self):
        from transformer.transform import transform_record
        raw = {
            "entity_id": "USER#u002",
            "event_type": "VIEW",
            "event_time": "2024-01-15T12:00:00Z",
            "metadata": {"page_path": "/home", "duration_seconds": 30},
        }
        result = transform_record(raw)
        assert result["event_type"] == "VIEW"
        assert result["payload"]["page_path"] == "/home"

    def test_click_record_returns_click_payload(self):
        from transformer.transform import transform_record
        raw = {
            "entity_id": "USER#u003",
            "event_type": "CLICK",
            "event_time": "2024-01-15T12:00:00Z",
            "metadata": {"element_id": "btn-cta", "click_x": 100, "click_y": 200},
        }
        result = transform_record(raw)
        assert result["event_type"] == "CLICK"
        assert result["payload"]["element_id"] == "btn-cta"

    def test_ttl_is_approximately_30_days_from_now(self):
        from transformer.transform import transform_record
        result = transform_record(BASE_RAW_DATA.copy())
        now = int(time.time())
        ttl_30_days = 30 * 24 * 3600
        assert abs(result["expires_at"] - (now + ttl_30_days)) < 60

    def test_unsupported_event_type_raises_transform_error(self):
        from transformer.transform import transform_record, TransformError
        raw = {**BASE_RAW_DATA, "event_type": "UNKNOWN"}
        with pytest.raises(TransformError):
            transform_record(raw)

    def test_missing_required_field_raises_transform_error(self):
        from transformer.transform import transform_record, TransformError
        raw = {k: v for k, v in BASE_RAW_DATA.items() if k != "entity_id"}
        with pytest.raises(TransformError):
            transform_record(raw)


# ── TestRecordHandler ────────────────────────────────────────────

class TestRecordHandler:
    """record_handler: Kinesis レコードの base64 デコード・変換。"""

    def test_valid_kinesis_record_returns_transformed_item(self):
        from transformer.handler import record_handler
        record = FakeKinesisStreamRecord(BASE_RAW_DATA)
        result = record_handler(record)
        assert result["entity_id"] == "USER#u001"
        assert result["event_type"] == "PURCHASE"
        assert result["status"] == "PENDING"

    def test_base64_decode_is_correct(self):
        """Kinesis の data（base64 文字列）が正しくデコードされて JSON パースされる。"""
        # Powertools は base64 デコード済みの文字列を record.data に格納するため、
        # FakeKinesisStreamRecord.data はすでにデコード済みの文字列を使用する。
        from transformer.handler import record_handler
        raw = {
            "entity_id": "PRODUCT#p001",
            "event_type": "view",
            "event_time": "2024-03-01T09:00:00Z",
            "metadata": {"page_path": "/products/p001"},
        }
        record = FakeKinesisStreamRecord(raw)
        result = record_handler(record)
        assert result["entity_id"] == "PRODUCT#p001"
        assert result["event_type"] == "VIEW"

    def test_invalid_json_raises_json_decode_error(self):
        from transformer.handler import record_handler
        record = FakeKinesisStreamRecord.__new__(FakeKinesisStreamRecord)
        record.data = "{ not valid json {{{"
        record.kinesis = FakeKinesisStreamRecord._Kinesis()
        with pytest.raises(json.JSONDecodeError):
            record_handler(record)

    def test_transform_error_is_propagated(self):
        """TransformError は BatchProcessor が失敗レコードとして扱うために伝播される。"""
        from transformer.transform import TransformError
        from transformer.handler import record_handler
        raw = {**BASE_RAW_DATA, "event_type": "UNSUPPORTED"}
        record = FakeKinesisStreamRecord(raw)
        with pytest.raises(TransformError):
            record_handler(record)


# ── TestWriteChunkWithRetry ──────────────────────────────────────

class TestWriteChunkWithRetry:
    """_write_chunk_with_retry: UnprocessedItems の指数バックオフ再試行。"""

    def test_successful_write_calls_batch_write_once(self, dynamodb_table):
        """UnprocessedItems がなければ 1 回のリクエストで完了する。"""
        from transformer.handler import _write_chunk_with_retry

        items = [
            {
                "entity_id": "USER#u001",
                "event_ts": "EVENT#2024-01-15T12:00:00Z",
                "status": "PENDING",
                "event_type": "PURCHASE",
                "payload": {"value": 1000},
                "transformed_at": "2024-01-15T12:00:00Z",
                "expires_at": 1735689600,
            }
        ]
        _write_chunk_with_retry(items)

        written = dynamodb_table.scan()["Items"]
        assert len(written) == 1
        assert written[0]["entity_id"] == "USER#u001"

    def test_unprocessed_items_are_retried(self):
        """
        batch_write_item が UnprocessedItems を返した場合、
        再試行でそれらのアイテムを送信する。
        """
        from transformer.handler import _write_chunk_with_retry, DYNAMODB_TABLE

        items = [{"entity_id": "USER#u001", "event_ts": "EVENT#2024-01-15T12:00:00Z"}]

        # 1 回目: UnprocessedItems あり, 2 回目: 全件処理完了
        mock_responses = [
            {
                "UnprocessedItems": {
                    DYNAMODB_TABLE: [
                        {"PutRequest": {"Item": {"entity_id": {"S": "USER#u001"}}}}
                    ]
                }
            },
            {"UnprocessedItems": {}},
        ]

        with patch("transformer.handler._dynamodb_client") as mock_client:
            mock_client.batch_write_item.side_effect = mock_responses
            with patch("time.sleep"):  # バックオフの実際の待機を省略
                _write_chunk_with_retry(items)

        # 2 回呼び出されている
        assert mock_client.batch_write_item.call_count == 2

    def test_max_retry_exceeded_logs_error_and_continues(self):
        """
        最大リトライ回数（_MAX_UNPROCESSED_RETRIES=3）を超えても例外は raise されない。
        BatchWriteErrors メトリクスが記録されて処理は継続する。
        """
        from transformer.handler import _write_chunk_with_retry, DYNAMODB_TABLE

        items = [{"entity_id": "USER#u001", "event_ts": "EVENT#2024-01-15T12:00:00Z"}]

        # 常に UnprocessedItems を返す（リトライ上限を超えさせる）
        unprocessed = {
            DYNAMODB_TABLE: [
                {"PutRequest": {"Item": {"entity_id": {"S": "USER#u001"}}}}
            ]
        }
        mock_response = {"UnprocessedItems": unprocessed}

        with patch("transformer.handler._dynamodb_client") as mock_client:
            mock_client.batch_write_item.return_value = mock_response
            with patch("time.sleep"):
                # 例外が raise されないことを確認
                _write_chunk_with_retry(items)

        # 初回 + 最大リトライ回数分呼ばれる（1 + _MAX_UNPROCESSED_RETRIES = 4）
        assert mock_client.batch_write_item.call_count == 4

    def test_25_items_are_written_in_single_chunk(self, dynamodb_table):
        """25 件以内はチャンク分割なしで 1 回の BatchWriteItem に収まる。"""
        from transformer.handler import _write_chunk_with_retry

        items = [
            {
                "entity_id": f"USER#u{i:03d}",
                "event_ts": f"EVENT#2024-01-15T{i:02d}:00:00Z",
                "status": "PENDING",
                "event_type": "VIEW",
                "payload": {},
                "transformed_at": "2024-01-15T12:00:00Z",
                "expires_at": 1735689600,
            }
            for i in range(25)
        ]
        _write_chunk_with_retry(items)

        written = dynamodb_table.scan()["Count"]
        assert written == 25


# ── TestLambdaHandler ────────────────────────────────────────────

class TestLambdaHandler:
    """lambda_handler: Kinesis バッチの全体フロー。"""

    def test_successful_batch_writes_to_dynamodb(self, dynamodb_table):
        """正常なバッチは batchItemFailures なしで DynamoDB に書き込まれる。"""
        from transformer.handler import lambda_handler

        records = [
            {
                "entity_id": "USER#u001",
                "event_type": "PURCHASE",
                "event_time": "2024-01-15T12:00:00Z",
                "value": 1500,
                "metadata": {},
            },
            {
                "entity_id": "USER#u002",
                "event_type": "VIEW",
                "event_time": "2024-01-15T12:05:00Z",
                "metadata": {"page_path": "/home"},
            },
        ]
        event = _make_kinesis_event(records)
        response = lambda_handler(event, FakeLambdaContext())

        assert response["batchItemFailures"] == []
        assert dynamodb_table.scan()["Count"] == 2

    def test_invalid_record_is_added_to_batch_item_failures(self, dynamodb_table):
        """
        バリデーション失敗レコードは batchItemFailures にシーケンス番号で追加される。
        正常なレコードはチェックポイントが進んで再処理されない。
        """
        from transformer.handler import lambda_handler

        records = [
            {
                "entity_id": "USER#u001",
                "event_type": "PURCHASE",
                "event_time": "2024-01-15T12:00:00Z",
                "value": 1000,
                "metadata": {},
            },  # 正常
            {
                "entity_id": "NO_HASH",  # 不正な entity_id
                "event_type": "VIEW",
                "event_time": "2024-01-15T12:05:00Z",
                "metadata": {},
            },  # 失敗
        ]
        event = _make_kinesis_event(records)
        response = lambda_handler(event, FakeLambdaContext())

        # 失敗したレコードのシーケンス番号が batchItemFailures に含まれる
        assert len(response["batchItemFailures"]) == 1
        failed_seq = response["batchItemFailures"][0]["itemIdentifier"]
        # 2 番目のレコードのシーケンス番号が含まれている
        assert failed_seq == event["Records"][1]["kinesis"]["sequenceNumber"]
        # 正常なレコードは DynamoDB に書き込まれている
        assert dynamodb_table.scan()["Count"] == 1

    def test_empty_records_returns_no_failures(self, dynamodb_table):
        from transformer.handler import lambda_handler
        response = lambda_handler({"Records": []}, FakeLambdaContext())
        assert response["batchItemFailures"] == []
        assert dynamodb_table.scan()["Count"] == 0

    def test_all_three_event_types_are_processed(self, dynamodb_table):
        """PURCHASE / VIEW / CLICK の 3 種類がすべて正常に変換・書き込まれる。"""
        from transformer.handler import lambda_handler

        records = [
            {
                "entity_id": "USER#u001",
                "event_type": "PURCHASE",
                "event_time": "2024-01-15T10:00:00Z",
                "value": 3000,
                "metadata": {"currency": "JPY"},
            },
            {
                "entity_id": "USER#u002",
                "event_type": "VIEW",
                "event_time": "2024-01-15T11:00:00Z",
                "metadata": {"page_path": "/products"},
            },
            {
                "entity_id": "USER#u003",
                "event_type": "CLICK",
                "event_time": "2024-01-15T12:00:00Z",
                "metadata": {"element_id": "btn-buy", "click_x": 100, "click_y": 200},
            },
        ]
        event = _make_kinesis_event(records)
        response = lambda_handler(event, FakeLambdaContext())

        assert response["batchItemFailures"] == []
        assert dynamodb_table.scan()["Count"] == 3
