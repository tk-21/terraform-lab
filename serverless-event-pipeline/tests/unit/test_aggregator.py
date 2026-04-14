"""
aggregator Lambda のユニットテスト

moto で DynamoDB をモックし、集計ロジックの正確性を検証する。

テスト構成:
  TestProcessRecord    — _process_record の単体テスト（DynamoDB 不要）
  TestUpdateAggregation — _update_aggregation の単体テスト（moto 使用）
  TestLambdaHandler    — lambda_handler の統合テスト（moto 使用）
"""

import os
from decimal import Decimal

import boto3
import pytest
from moto import mock_aws

# Powertools の初期化に必要な環境変数を conftest.py の autouse fixture より先に設定する。
# conftest.py の aws_credentials fixture は各テスト前に実行されるが、
# モジュールインポートはそれより前に行われることがあるため、ここでも setdefault を使用する。
os.environ.setdefault("AGGREGATIONS_TABLE_NAME", "sep-test-aggregations")
os.environ.setdefault("POWERTOOLS_SERVICE_NAME", "sep-test-aggregator")
os.environ.setdefault("POWERTOOLS_METRICS_NAMESPACE", "ServerlessEventPipeline")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")


# ── テスト用フィクスチャ ──────────────────────────────────────────

@pytest.fixture
def aggregations_table(aws_credentials):
    """sep-test-aggregations DynamoDB テーブルを moto で作成するフィクスチャ。"""
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")
        table = dynamodb.create_table(
            TableName="sep-test-aggregations",
            KeySchema=[
                {"AttributeName": "aggregate_key", "KeyType": "HASH"},
                {"AttributeName": "metric_type", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "aggregate_key", "AttributeType": "S"},
                {"AttributeName": "metric_type", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        yield table


# ── テストデータ生成ヘルパー ──────────────────────────────────────

def _make_streams_record(
    event_name: str,
    entity_id: str,
    event_ts: str,
    event_type: str,
    value: float | None = None,
    old_value: float | None = None,
    old_status: str = "PENDING",
) -> dict:
    """
    テスト用 DynamoDB Streams レコードを生成するヘルパー。

    DynamoDB Streams は TypedDict フォーマット（{"S": "..."}, {"N": "..."}）で
    イメージを提供するため、実際の Streams 形式に合わせて生成する。
    """
    new_image = {
        "entity_id": {"S": entity_id},
        "event_ts": {"S": event_ts},
        "status": {"S": "PENDING"},
        "payload": {
            "M": {
                "event_type": {"S": event_type},
                **({"value": {"N": str(value)}} if value is not None else {}),
            }
        },
    }

    record: dict = {
        "eventID": "test-event-id-001",
        "eventName": event_name,
        "dynamodb": {
            "NewImage": new_image,
            "SequenceNumber": "1234567890",
        },
    }

    # MODIFY の場合は OldImage を設定する
    if event_name == "MODIFY":
        record["dynamodb"]["OldImage"] = {
            "entity_id": {"S": entity_id},
            "event_ts": {"S": event_ts},
            "status": {"S": old_status},
            "payload": {
                "M": {
                    "event_type": {"S": event_type},
                    **({"value": {"N": str(old_value)}} if old_value is not None else {}),
                }
            },
        }

    return record


class FakeLambdaContext:
    """テスト用の LambdaContext モック。"""
    function_name = "sep-test-aggregator"
    memory_limit_in_mb = 256
    invoked_function_arn = (
        "arn:aws:lambda:ap-northeast-1:123456789012:function:sep-test-aggregator"
    )
    aws_request_id = "test-request-id-0001"


# ── _process_record のテスト ──────────────────────────────────────

class TestProcessRecord:
    """_process_record 関数の単体テスト（DynamoDB 接続不要）。"""

    def test_remove_event_returns_empty_list(self):
        """REMOVE イベントは集計オペレーションを生成せず空リストを返す。"""
        from aggregator.handler import _process_record

        record = {
            "eventName": "REMOVE",
            "eventID": "remove-001",
            "dynamodb": {
                "OldImage": {
                    "entity_id": {"S": "USER#u123"},
                    "event_ts": {"S": "EVENT#2024-01-15T12:00:00Z"},
                }
            },
        }
        result = _process_record(record)
        assert result == []

    def test_insert_purchase_creates_total_amount_operation(self):
        """INSERT PURCHASE イベントが TOTAL_AMOUNT 集計オペレーションを生成する。"""
        from aggregator.handler import _process_record

        record = _make_streams_record(
            event_name="INSERT",
            entity_id="USER#u123",
            event_ts="EVENT#2024-01-15T12:00:00Z",
            event_type="purchase",
            value=1500.0,
        )
        operations = _process_record(record)

        assert len(operations) == 1
        op = operations[0]
        assert op["aggregate_key"] == "USER#u123#2024-01-15"
        assert op["metric_type"] == "TOTAL_AMOUNT"
        assert op["value_delta"] == Decimal("1500.0")
        assert op["count_delta"] == 1

    def test_insert_view_creates_view_count_operation(self):
        """INSERT VIEW イベントが VIEW_COUNT 集計オペレーションを生成する。"""
        from aggregator.handler import _process_record

        record = _make_streams_record(
            event_name="INSERT",
            entity_id="USER#u456",
            event_ts="EVENT#2024-01-15T09:30:00Z",
            event_type="view",
        )
        operations = _process_record(record)

        assert len(operations) == 1
        op = operations[0]
        assert op["aggregate_key"] == "USER#u456#2024-01-15"
        assert op["metric_type"] == "VIEW_COUNT"
        assert op["value_delta"] == Decimal("1")
        assert op["count_delta"] == 1

    def test_modify_purchase_aggregates_delta_only(self):
        """
        MODIFY PURCHASE イベントは新旧イメージの差分金額のみ集計する。

        【DynamoDB Streams at-least-once 配信への対応】
        同一 MODIFY が再配信されても差分は変わらないため、二重集計の影響がない。
        """
        from aggregator.handler import _process_record

        record = _make_streams_record(
            event_name="MODIFY",
            entity_id="USER#u123",
            event_ts="EVENT#2024-01-15T12:00:00Z",
            event_type="purchase",
            value=2000.0,
            old_value=1500.0,
        )
        operations = _process_record(record)

        assert len(operations) == 1
        op = operations[0]
        # 差分のみ加算: 2000 - 1500 = 500
        assert op["value_delta"] == Decimal("500.0")
        # MODIFY はカウント加算しない（既存イベントの更新のため二重カウント禁止）
        assert op["count_delta"] == 0

    def test_modify_purchase_zero_delta_skips_operation(self):
        """MODIFY PURCHASE で金額差分が 0 の場合はオペレーションを生成しない。"""
        from aggregator.handler import _process_record

        # ステータス変更のみで金額が変わらない MODIFY（例: PENDING → PROCESSED）
        record = _make_streams_record(
            event_name="MODIFY",
            entity_id="USER#u123",
            event_ts="EVENT#2024-01-15T12:00:00Z",
            event_type="purchase",
            value=1500.0,
            old_value=1500.0,  # 金額変化なし
            old_status="PENDING",
        )
        operations = _process_record(record)

        # value_delta=0, count_delta=0 のためオペレーションなし
        assert operations == []

    def test_modify_view_skips_operation(self):
        """MODIFY VIEW イベントは count_delta=0 のためオペレーションを生成しない。"""
        from aggregator.handler import _process_record

        record = _make_streams_record(
            event_name="MODIFY",
            entity_id="USER#u789",
            event_ts="EVENT#2024-01-15T09:30:00Z",
            event_type="view",
        )
        operations = _process_record(record)

        # VIEW の MODIFY: 集計値は変化しない
        assert operations == []

    def test_unknown_event_type_is_skipped(self):
        """集計対象外のイベント種別（click など）はスキップされる。"""
        from aggregator.handler import _process_record

        record = _make_streams_record(
            event_name="INSERT",
            entity_id="USER#u123",
            event_ts="EVENT#2024-01-15T12:00:00Z",
            event_type="click",
        )
        operations = _process_record(record)
        assert operations == []

    def test_event_type_is_case_insensitive(self):
        """event_type の大文字・小文字を正規化して処理する（PURCHASE = purchase）。"""
        from aggregator.handler import _process_record

        # 大文字の PURCHASE
        record_upper = _make_streams_record(
            event_name="INSERT",
            entity_id="USER#u123",
            event_ts="EVENT#2024-01-15T12:00:00Z",
            event_type="PURCHASE",
            value=500.0,
        )
        # 小文字の purchase
        record_lower = _make_streams_record(
            event_name="INSERT",
            entity_id="USER#u123",
            event_ts="EVENT#2024-01-15T12:00:00Z",
            event_type="purchase",
            value=500.0,
        )
        ops_upper = _process_record(record_upper)
        ops_lower = _process_record(record_lower)

        assert len(ops_upper) == 1
        assert len(ops_lower) == 1
        assert ops_upper[0]["metric_type"] == ops_lower[0]["metric_type"]

    def test_aggregate_key_groups_by_entity_and_date(self):
        """aggregate_key が entity_id と日付の組み合わせになっている。"""
        from aggregator.handler import _process_record

        record = _make_streams_record(
            event_name="INSERT",
            entity_id="PRODUCT#p001",
            event_ts="EVENT#2024-03-20T23:59:59Z",
            event_type="purchase",
            value=100.0,
        )
        operations = _process_record(record)

        assert operations[0]["aggregate_key"] == "PRODUCT#p001#2024-03-20"

    def test_missing_entity_id_returns_empty_list(self):
        """entity_id が欠損しているレコードはスキップされる。"""
        from aggregator.handler import _process_record

        record = {
            "eventName": "INSERT",
            "eventID": "bad-record-001",
            "dynamodb": {
                "NewImage": {
                    # entity_id が欠損
                    "event_ts": {"S": "EVENT#2024-01-15T12:00:00Z"},
                    "payload": {"M": {"event_type": {"S": "purchase"}}},
                }
            },
        }
        operations = _process_record(record)
        assert operations == []


# ── _update_aggregation のテスト ──────────────────────────────────

class TestUpdateAggregation:
    """_update_aggregation 関数の単体テスト（moto で DynamoDB をモック）。"""

    def test_new_item_is_created_with_correct_values(self, aggregations_table):
        """集計レコードが存在しない場合は新規作成（upsert）される。"""
        from aggregator.handler import _update_aggregation

        _update_aggregation(
            table=aggregations_table,
            aggregate_key="USER#u123#2024-01-15",
            metric_type="TOTAL_AMOUNT",
            value_delta=Decimal("1500"),
            count_delta=1,
        )

        item = aggregations_table.get_item(
            Key={"aggregate_key": "USER#u123#2024-01-15", "metric_type": "TOTAL_AMOUNT"}
        ).get("Item")

        assert item is not None
        assert item["value"] == Decimal("1500")
        assert item["count"] == 1
        assert "updated_at" in item

    def test_existing_item_is_atomically_incremented(self, aggregations_table):
        """既存の集計レコードに ADD 式でアトミック加算される。"""
        from aggregator.handler import _update_aggregation

        # 1回目の加算
        _update_aggregation(
            table=aggregations_table,
            aggregate_key="USER#u123#2024-01-15",
            metric_type="TOTAL_AMOUNT",
            value_delta=Decimal("1000"),
            count_delta=1,
        )
        # 2回目の加算
        _update_aggregation(
            table=aggregations_table,
            aggregate_key="USER#u123#2024-01-15",
            metric_type="TOTAL_AMOUNT",
            value_delta=Decimal("500"),
            count_delta=1,
        )

        item = aggregations_table.get_item(
            Key={"aggregate_key": "USER#u123#2024-01-15", "metric_type": "TOTAL_AMOUNT"}
        ).get("Item")

        # 1000 + 500 = 1500、count: 1 + 1 = 2
        assert item["value"] == Decimal("1500")
        assert item["count"] == 2

    def test_different_metric_types_are_stored_separately(self, aggregations_table):
        """同一 aggregate_key でも metric_type が異なれば別レコードとして保存される。"""
        from aggregator.handler import _update_aggregation

        _update_aggregation(
            table=aggregations_table,
            aggregate_key="USER#u001#2024-02-01",
            metric_type="TOTAL_AMOUNT",
            value_delta=Decimal("3000"),
            count_delta=2,
        )
        _update_aggregation(
            table=aggregations_table,
            aggregate_key="USER#u001#2024-02-01",
            metric_type="VIEW_COUNT",
            value_delta=Decimal("5"),
            count_delta=5,
        )

        purchase = aggregations_table.get_item(
            Key={"aggregate_key": "USER#u001#2024-02-01", "metric_type": "TOTAL_AMOUNT"}
        ).get("Item")
        view = aggregations_table.get_item(
            Key={"aggregate_key": "USER#u001#2024-02-01", "metric_type": "VIEW_COUNT"}
        ).get("Item")

        assert purchase["value"] == Decimal("3000")
        assert view["value"] == Decimal("5")


# ── lambda_handler の統合テスト ───────────────────────────────────

class TestLambdaHandler:
    """lambda_handler の統合テスト（moto + フル処理フロー）。"""

    def test_handler_processes_purchase_and_view_events(self, aggregations_table):
        """複数イベントを含む Streams バッチを正常に処理して集計テーブルを更新する。"""
        from aggregator.handler import lambda_handler

        event = {
            "Records": [
                _make_streams_record(
                    event_name="INSERT",
                    entity_id="USER#u001",
                    event_ts="EVENT#2024-01-15T10:00:00Z",
                    event_type="purchase",
                    value=3000.0,
                ),
                _make_streams_record(
                    event_name="INSERT",
                    entity_id="USER#u001",
                    event_ts="EVENT#2024-01-15T11:00:00Z",
                    event_type="view",
                ),
            ]
        }

        lambda_handler(event, FakeLambdaContext())

        purchase_item = aggregations_table.get_item(
            Key={"aggregate_key": "USER#u001#2024-01-15", "metric_type": "TOTAL_AMOUNT"}
        ).get("Item")
        view_item = aggregations_table.get_item(
            Key={"aggregate_key": "USER#u001#2024-01-15", "metric_type": "VIEW_COUNT"}
        ).get("Item")

        assert purchase_item is not None
        assert purchase_item["value"] == Decimal("3000")
        assert purchase_item["count"] == 1

        assert view_item is not None
        assert view_item["value"] == Decimal("1")
        assert view_item["count"] == 1

    def test_handler_skips_remove_events_without_writing(self, aggregations_table):
        """REMOVE イベントのみのバッチは集計テーブルへの書き込みが発生しない。"""
        from aggregator.handler import lambda_handler

        event = {
            "Records": [
                {
                    "eventName": "REMOVE",
                    "eventID": "remove-001",
                    "dynamodb": {
                        "OldImage": {
                            "entity_id": {"S": "USER#u123"},
                            "event_ts": {"S": "EVENT#2024-01-15T12:00:00Z"},
                        }
                    },
                }
            ]
        }

        lambda_handler(event, FakeLambdaContext())

        scan_result = aggregations_table.scan()
        assert scan_result["Count"] == 0

    def test_handler_accumulates_multiple_purchases_per_day(self, aggregations_table):
        """同日の複数 PURCHASE イベントが正しく累積集計される。"""
        from aggregator.handler import lambda_handler

        event = {
            "Records": [
                _make_streams_record(
                    event_name="INSERT",
                    entity_id="USER#u001",
                    event_ts="EVENT#2024-01-20T09:00:00Z",
                    event_type="purchase",
                    value=1000.0,
                ),
                _make_streams_record(
                    event_name="INSERT",
                    entity_id="USER#u001",
                    event_ts="EVENT#2024-01-20T14:00:00Z",
                    event_type="purchase",
                    value=2500.0,
                ),
                _make_streams_record(
                    event_name="INSERT",
                    entity_id="USER#u001",
                    event_ts="EVENT#2024-01-20T18:30:00Z",
                    event_type="purchase",
                    value=500.0,
                ),
            ]
        }

        lambda_handler(event, FakeLambdaContext())

        item = aggregations_table.get_item(
            Key={"aggregate_key": "USER#u001#2024-01-20", "metric_type": "TOTAL_AMOUNT"}
        ).get("Item")

        # 1000 + 2500 + 500 = 4000
        assert item["value"] == Decimal("4000")
        assert item["count"] == 3

    def test_handler_continues_processing_on_individual_error(self, aggregations_table):
        """
        個別レコードのエラーが発生しても後続レコードの処理は継続される。

        Lambda が例外をスローしないことで、bisect_on_function_error が
        発動せず全バッチが適切に処理される。
        """
        from aggregator.handler import lambda_handler

        event = {
            "Records": [
                # 不正なレコード（NewImage が空）
                {
                    "eventName": "INSERT",
                    "eventID": "bad-record-001",
                    "dynamodb": {"NewImage": {}},
                },
                # 正常なレコード
                _make_streams_record(
                    event_name="INSERT",
                    entity_id="USER#u002",
                    event_ts="EVENT#2024-01-25T10:00:00Z",
                    event_type="purchase",
                    value=800.0,
                ),
            ]
        }

        # 例外が発生せず正常終了することを確認
        lambda_handler(event, FakeLambdaContext())

        # 正常なレコードは集計テーブルに書き込まれている
        item = aggregations_table.get_item(
            Key={"aggregate_key": "USER#u002#2024-01-25", "metric_type": "TOTAL_AMOUNT"}
        ).get("Item")
        assert item is not None
        assert item["value"] == Decimal("800")

    def test_handler_handles_empty_records(self, aggregations_table):
        """Records が空のイベントを受け取っても例外が発生しない。"""
        from aggregator.handler import lambda_handler

        lambda_handler({"Records": []}, FakeLambdaContext())

        scan_result = aggregations_table.scan()
        assert scan_result["Count"] == 0
