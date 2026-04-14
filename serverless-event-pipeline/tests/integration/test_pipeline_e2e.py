"""
パイプライン E2E 統合テスト
実 AWS リソース（dev 環境）を使用して、データフローの全体を検証する。

前提条件:
  - dev 環境に Terraform が適用済みであること
  - tests/integration/conftest.py に記載の環境変数が設定済みであること
  - 実行: make test-integration

テスト戦略:
  1. S3 にサンプルデータをアップロード
  2. SQS メッセージのポーリングで Lambda 起動を確認
  3. DynamoDB に期待するレコードが書き込まれるまで最大 60 秒待機
  4. 集計テーブルの値を検証
  5. CloudWatch カスタムメトリクスの記録を確認
  6. テスト後にアップロードした S3 オブジェクトを削除（cleanup）

注意事項:
  - at-least-once 配信により、一部テストは非決定論的になる場合がある。
  - テスト用に固定の entity_id (TEST#e2e-<uuid>) を使用して他データと混在しないようにする。
  - 並行テスト実行は避けること（DynamoDB の集計値が競合する）。
"""
import json
import time
import uuid
from datetime import datetime, timezone

import pytest
from boto3.dynamodb.conditions import Key

# ── 定数 ────────────────────────────────────────────────────────

# SQS ポーリング設定: 最大 60 秒（5 秒 × 12 回）
POLLING_INTERVAL_SEC = 5
MAX_POLLING_RETRIES = 12

# DynamoDB 書き込み待機設定: 最大 60 秒
DYNAMODB_WAIT_TIMEOUT_SEC = 60
DYNAMODB_POLL_INTERVAL_SEC = 3


# ── ヘルパー ─────────────────────────────────────────────────────

def _unique_entity_id() -> str:
    """テスト実行ごとにユニークな entity_id を生成して他データと分離する。"""
    return f"TEST#e2e-{uuid.uuid4().hex[:8]}"


def _queue_counts(sqs_client, queue_url: str) -> tuple[int, int]:
    """SQS キューの可視/不可視メッセージ件数を返す。"""
    response = sqs_client.get_queue_attributes(
        QueueUrl=queue_url,
        AttributeNames=[
            "ApproximateNumberOfMessages",
            "ApproximateNumberOfMessagesNotVisible",
        ],
    )
    attrs = response["Attributes"]
    visible = int(attrs.get("ApproximateNumberOfMessages", "0"))
    not_visible = int(attrs.get("ApproximateNumberOfMessagesNotVisible", "0"))
    return visible, not_visible


def _wait_for_lambda_trigger_via_sqs_polling(
    sqs_client,
    queue_url: str,
    baseline_visible: int,
    baseline_not_visible: int,
    polling_interval: int = POLLING_INTERVAL_SEC,
    max_retries: int = MAX_POLLING_RETRIES,
) -> bool:
    """
    SQS キュー属性を 5 秒 × 12 回ポーリングし、Lambda がメッセージを拾い始めたことを確認する。

    判定条件:
      - In-Flight（NotVisible）が増える
      - または Visible 件数が送信直後の想定値から減少する
    """
    expected_visible_after_send = baseline_visible + 1

    for _ in range(max_retries):
        visible, not_visible = _queue_counts(sqs_client, queue_url)
        if not_visible > baseline_not_visible:
            return True
        if visible < expected_visible_after_send:
            return True
        time.sleep(polling_interval)

    return False


def _wait_for_dynamodb_item(
    table,
    entity_id: str,
    event_ts_prefix: str,
    timeout: int = DYNAMODB_WAIT_TIMEOUT_SEC,
    poll_interval: int = DYNAMODB_POLL_INTERVAL_SEC,
) -> dict | None:
    """
    DynamoDB に期待するレコードが書き込まれるまでポーリングする。

    Args:
        table: boto3 DynamoDB Table リソース
        entity_id: 検索する entity_id（PK）
        event_ts_prefix: SK の begins_with フィルター（例: "EVENT#2024-01-15"）
        timeout: タイムアウト秒数
        poll_interval: ポーリング間隔秒数

    Returns:
        見つかったアイテム dict、タイムアウトした場合は None
    """
    from boto3.dynamodb.conditions import Key

    deadline = time.time() + timeout
    while time.time() < deadline:
        response = table.query(
            KeyConditionExpression=(
                Key("entity_id").eq(entity_id)
                & Key("event_ts").begins_with(event_ts_prefix)
            ),
            Limit=1,
        )
        if response["Items"]:
            return response["Items"][0]
        time.sleep(poll_interval)

    return None


def _wait_for_aggregation(
    table,
    aggregate_key: str,
    metric_type: str,
    timeout: int = DYNAMODB_WAIT_TIMEOUT_SEC,
    poll_interval: int = DYNAMODB_POLL_INTERVAL_SEC,
) -> dict | None:
    """集計テーブルのレコードが書き込まれるまでポーリングする。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        response = table.get_item(
            Key={"aggregate_key": aggregate_key, "metric_type": metric_type}
        )
        item = response.get("Item")
        if item:
            return item
        time.sleep(poll_interval)

    return None


@pytest.fixture
def integration_cleanup(s3_client, raw_input_bucket, events_table, aggregations_table):
    """統合テストで作成した S3 / DynamoDB データをテスト終了後に削除する。"""
    state = {
        "s3_keys": [],
        "event_records": [],
        "aggregation_records": [],
    }
    yield state

    for key in state["s3_keys"]:
        try:
            s3_client.delete_object(Bucket=raw_input_bucket, Key=key)
        except Exception:
            pass

    for entity_id, event_ts in state["event_records"]:
        try:
            events_table.delete_item(Key={"entity_id": entity_id, "event_ts": event_ts})
        except Exception:
            pass

    for aggregate_key, metric_type in state["aggregation_records"]:
        try:
            aggregations_table.delete_item(
                Key={"aggregate_key": aggregate_key, "metric_type": metric_type}
            )
        except Exception:
            pass


def _make_s3_notification_body(bucket: str, key: str, size: int) -> str:
    """SQS に直接送信する S3 通知の JSON 文字列を生成する。"""
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


# ── テストクラス ─────────────────────────────────────────────────

@pytest.mark.integration
class TestIngestorE2E:
    """
    S3 PUT → SQS → ingestor Lambda → DynamoDB の E2E フロー検証。

    テスト手順:
      1. テスト用 JSON ファイルを S3 にアップロード
      2. S3 通知を SQS に手動送信（S3 バケット通知をシミュレート）
      3. DynamoDB にレコードが書き込まれるまで待機（最大 60 秒）
      4. レコードの内容を検証
      5. テスト後に S3 オブジェクトを削除（cleanup）
    """

    def test_json_file_ingestion_creates_dynamodb_record(
        self,
        s3_client,
        sqs_client,
        events_table,
        raw_input_bucket,
        ingest_queue_url,
        integration_cleanup,
    ):
        """
        JSON ファイルを S3 にアップロードして SQS 経由で ingestor Lambda をトリガーし、
        DynamoDB に期待するレコードが書き込まれることを確認する。
        """
        entity_id = _unique_entity_id()
        event_time = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        event_ts_prefix = f"EVENT#{event_time[:10]}"

        # テストデータ
        records = [
            {
                "entity_id": entity_id,
                "event_type": "purchase",
                "event_time": event_time,
                "value": 2500.0,
                "metadata": {"product_id": "test-product-001"},
            }
        ]

        visible_before, not_visible_before = _queue_counts(sqs_client, ingest_queue_url)

        # S3 にアップロード
        s3_key = f"e2e-test/{entity_id}/events.json"
        s3_client.put_object(
            Bucket=raw_input_bucket,
            Key=s3_key,
            Body=json.dumps(records).encode("utf-8"),
            ContentType="application/json",
        )
        integration_cleanup["s3_keys"].append(s3_key)

        # SQS に S3 通知を送信（Lambda のトリガーをシミュレート）
        sqs_client.send_message(
            QueueUrl=ingest_queue_url,
            MessageBody=_make_s3_notification_body(
                bucket=raw_input_bucket,
                key=s3_key,
                size=len(json.dumps(records)),
            ),
        )

        assert _wait_for_lambda_trigger_via_sqs_polling(
            sqs_client=sqs_client,
            queue_url=ingest_queue_url,
            baseline_visible=visible_before,
            baseline_not_visible=not_visible_before,
        ), "SQS ポーリングで Lambda 起動を確認できませんでした"

        # DynamoDB にレコードが書き込まれるまで待機（最大 60 秒）
        item = _wait_for_dynamodb_item(
            table=events_table,
            entity_id=entity_id,
            event_ts_prefix=event_ts_prefix,
        )

        assert item is not None, (
            f"DynamoDB にレコードが書き込まれませんでした: entity_id={entity_id}, "
            f"タイムアウト={DYNAMODB_WAIT_TIMEOUT_SEC}秒"
        )

        # レコードの内容を検証
        assert item["entity_id"] == entity_id
        assert item["status"] == "PENDING"
        assert item["source_bucket"] == raw_input_bucket
        assert item["source_key"] == s3_key
        assert item["event_ts"].startswith("EVENT#")
        assert "ingested_at" in item
        assert "expires_at" in item
        integration_cleanup["event_records"].append((item["entity_id"], item["event_ts"]))

    def test_csv_file_ingestion_creates_multiple_records(
        self,
        s3_client,
        sqs_client,
        events_table,
        raw_input_bucket,
        ingest_queue_url,
        integration_cleanup,
    ):
        """
        CSV ファイルの複数行がそれぞれ DynamoDB レコードとして書き込まれる。
        """
        now = datetime.now(timezone.utc)
        entity_id_1 = _unique_entity_id()
        entity_id_2 = _unique_entity_id()
        event_time_1 = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        # 2 番目のレコードは 1 秒後のタイムスタンプを使用（SK の衝突を防ぐ）
        event_time_2 = now.replace(second=(now.second + 1) % 60).strftime("%Y-%m-%dT%H:%M:%SZ")

        csv_content = (
            "entity_id,event_type,event_time,value\n"
            f"{entity_id_1},view,{event_time_1},0\n"
            f"{entity_id_2},purchase,{event_time_2},5000\n"
        )

        visible_before, not_visible_before = _queue_counts(sqs_client, ingest_queue_url)

        s3_key = f"e2e-test/csv-batch/events.csv"
        s3_client.put_object(
            Bucket=raw_input_bucket,
            Key=s3_key,
            Body=csv_content.encode("utf-8"),
            ContentType="text/csv",
        )
        integration_cleanup["s3_keys"].append(s3_key)

        sqs_client.send_message(
            QueueUrl=ingest_queue_url,
            MessageBody=_make_s3_notification_body(
                bucket=raw_input_bucket,
                key=s3_key,
                size=len(csv_content),
            ),
        )

        assert _wait_for_lambda_trigger_via_sqs_polling(
            sqs_client=sqs_client,
            queue_url=ingest_queue_url,
            baseline_visible=visible_before,
            baseline_not_visible=not_visible_before,
        ), "SQS ポーリングで Lambda 起動を確認できませんでした"

        date_prefix = f"EVENT#{now.strftime('%Y-%m-%d')}"

        # 両レコードが書き込まれるまで待機
        item_1 = _wait_for_dynamodb_item(events_table, entity_id_1, date_prefix)
        item_2 = _wait_for_dynamodb_item(events_table, entity_id_2, date_prefix)

        assert item_1 is not None, f"entity_id_1 ({entity_id_1}) が DynamoDB に書き込まれませんでした"
        assert item_2 is not None, f"entity_id_2 ({entity_id_2}) が DynamoDB に書き込まれませんでした"
        integration_cleanup["event_records"].append((item_1["entity_id"], item_1["event_ts"]))
        integration_cleanup["event_records"].append((item_2["entity_id"], item_2["event_ts"]))

    def test_duplicate_sqs_message_does_not_create_duplicate_record(
        self,
        s3_client,
        sqs_client,
        events_table,
        raw_input_bucket,
        ingest_queue_url,
        integration_cleanup,
    ):
        """
        同一 S3 ファイルを指す SQS メッセージが重複配信されても、
        DynamoDB にはレコードが 1 件のみ書き込まれる（冪等性の保証）。
        """
        entity_id = _unique_entity_id()
        event_time = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        records = [
            {
                "entity_id": entity_id,
                "event_type": "view",
                "event_time": event_time,
                "metadata": {},
            }
        ]

        visible_before, not_visible_before = _queue_counts(sqs_client, ingest_queue_url)

        s3_key = f"e2e-test/idempotency/{entity_id}/events.json"
        s3_client.put_object(
            Bucket=raw_input_bucket,
            Key=s3_key,
            Body=json.dumps(records).encode("utf-8"),
        )
        integration_cleanup["s3_keys"].append(s3_key)

        notification_body = _make_s3_notification_body(
            bucket=raw_input_bucket,
            key=s3_key,
            size=len(json.dumps(records)),
        )

        # 同一メッセージを 2 回送信（at-least-once 配信のシミュレーション）
        sqs_client.send_message(QueueUrl=ingest_queue_url, MessageBody=notification_body)
        sqs_client.send_message(QueueUrl=ingest_queue_url, MessageBody=notification_body)

        assert _wait_for_lambda_trigger_via_sqs_polling(
            sqs_client=sqs_client,
            queue_url=ingest_queue_url,
            baseline_visible=visible_before,
            baseline_not_visible=not_visible_before,
        ), "SQS ポーリングで Lambda 起動を確認できませんでした"

        date_prefix = f"EVENT#{event_time[:10]}"
        item = _wait_for_dynamodb_item(events_table, entity_id, date_prefix)
        if item:
            integration_cleanup["event_records"].append((item["entity_id"], item["event_ts"]))

        # 追加処理が完了するまで余分に待機
        time.sleep(10)

        # DynamoDB を PK でクエリして重複がないことを確認
        response = events_table.query(
            KeyConditionExpression=Key("entity_id").eq(entity_id)
        )
        assert response["Count"] == 1, (
            f"重複レコードが書き込まれました: entity_id={entity_id}, count={response['Count']}"
        )


@pytest.mark.integration
class TestAggregatorE2E:
    """
    DynamoDB Streams → aggregator Lambda → aggregations テーブルの E2E 検証。

    ingestor が events テーブルに書き込んだレコードに対して、
    DynamoDB Streams を通じて aggregator Lambda が起動し、
    aggregations テーブルに集計結果が書き込まれることを確認する。
    """

    def test_purchase_event_creates_total_amount_aggregation(
        self,
        s3_client,
        sqs_client,
        events_table,
        aggregations_table,
        raw_input_bucket,
        ingest_queue_url,
        integration_cleanup,
    ):
        """
        PURCHASE イベントが ingestor で処理されると、
        aggregator が DynamoDB Streams を受信して集計テーブルを更新する。
        """
        entity_id = _unique_entity_id()
        purchase_value = 3000.0
        event_time = datetime.now(timezone.utc)
        event_time_str = event_time.strftime("%Y-%m-%dT%H:%M:%SZ")
        date_str = event_time.strftime("%Y-%m-%d")

        visible_before, not_visible_before = _queue_counts(sqs_client, ingest_queue_url)

        records = [
            {
                "entity_id": entity_id,
                "event_type": "purchase",
                "event_time": event_time_str,
                "value": purchase_value,
                "metadata": {},
            }
        ]
        s3_key = f"e2e-test/aggregation/{entity_id}/events.json"
        s3_client.put_object(
            Bucket=raw_input_bucket,
            Key=s3_key,
            Body=json.dumps(records).encode("utf-8"),
        )
        integration_cleanup["s3_keys"].append(s3_key)

        sqs_client.send_message(
            QueueUrl=ingest_queue_url,
            MessageBody=_make_s3_notification_body(
                bucket=raw_input_bucket,
                key=s3_key,
                size=len(json.dumps(records)),
            ),
        )

        assert _wait_for_lambda_trigger_via_sqs_polling(
            sqs_client=sqs_client,
            queue_url=ingest_queue_url,
            baseline_visible=visible_before,
            baseline_not_visible=not_visible_before,
        ), "SQS ポーリングで Lambda 起動を確認できませんでした"

        # ingestor の DynamoDB 書き込みを待機
        date_prefix = f"EVENT#{date_str}"
        item = _wait_for_dynamodb_item(events_table, entity_id, date_prefix)
        assert item is not None, f"ingestor が events テーブルに書き込みませんでした: {entity_id}"
        integration_cleanup["event_records"].append((item["entity_id"], item["event_ts"]))

        # aggregator の DynamoDB 書き込みを待機（Streams の遅延を考慮してさらに待つ）
        aggregate_key = f"{entity_id}#{date_str}"
        agg_item = _wait_for_aggregation(
            table=aggregations_table,
            aggregate_key=aggregate_key,
            metric_type="TOTAL_AMOUNT",
            timeout=90,  # Streams の遅延を考慮して少し長めに待つ
        )

        assert agg_item is not None, (
            f"aggregator が集計テーブルに書き込みませんでした: aggregate_key={aggregate_key}"
        )
        assert float(agg_item["value"]) == purchase_value
        assert int(agg_item["count"]) >= 1
        integration_cleanup["aggregation_records"].append((aggregate_key, "TOTAL_AMOUNT"))


@pytest.mark.integration
class TestCloudWatchMetricsE2E:
    """
    Lambda が CloudWatch カスタムメトリクスを記録することを確認する。

    Powertools の EMF 形式でメトリクスが送信されるため、
    Lambda 実行後に CloudWatch Logs の Metric Filter 経由でメトリクスが記録される。
    """

    def test_processed_records_metric_is_published(
        self,
        s3_client,
        sqs_client,
        cloudwatch_client,
        raw_input_bucket,
        ingest_queue_url,
        integration_cleanup,
    ):
        """
        ingestor Lambda が実行された後、CloudWatch に ProcessedRecords メトリクスが
        記録されていることを確認する。
        """
        entity_id = _unique_entity_id()
        event_time = datetime.now(timezone.utc)
        event_time_str = event_time.strftime("%Y-%m-%dT%H:%M:%SZ")

        visible_before, not_visible_before = _queue_counts(sqs_client, ingest_queue_url)

        records = [
            {
                "entity_id": entity_id,
                "event_type": "view",
                "event_time": event_time_str,
                "metadata": {},
            }
        ]
        s3_key = f"e2e-test/metrics/{entity_id}/events.json"
        s3_client.put_object(
            Bucket=raw_input_bucket,
            Key=s3_key,
            Body=json.dumps(records).encode("utf-8"),
        )
        integration_cleanup["s3_keys"].append(s3_key)

        sqs_client.send_message(
            QueueUrl=ingest_queue_url,
            MessageBody=_make_s3_notification_body(
                bucket=raw_input_bucket,
                key=s3_key,
                size=len(json.dumps(records)),
            ),
        )

        assert _wait_for_lambda_trigger_via_sqs_polling(
            sqs_client=sqs_client,
            queue_url=ingest_queue_url,
            baseline_visible=visible_before,
            baseline_not_visible=not_visible_before,
        ), "SQS ポーリングで Lambda 起動を確認できませんでした"

        # Lambda 実行・CloudWatch への Metric 転送を待機
        time.sleep(30)

        # ProcessedRecords メトリクスが直近 5 分以内に記録されているか確認する
        response = cloudwatch_client.get_metric_statistics(
            Namespace="ServerlessEventPipeline",
            MetricName="ProcessedRecords",
            Dimensions=[],
            StartTime=event_time,
            EndTime=datetime.now(timezone.utc),
            Period=300,  # 5 分間の集計
            Statistics=["Sum"],
        )

        # メトリクスデータポイントが 1 件以上存在する
        assert len(response["Datapoints"]) > 0, (
            "CloudWatch に ProcessedRecords メトリクスが記録されていません。"
            "Lambda が正常に実行されているか確認してください。"
        )
        total_processed = sum(dp["Sum"] for dp in response["Datapoints"])
        assert total_processed >= 1


@pytest.mark.integration
class TestDLQE2E:
    """
    処理失敗時の DLQ への転送を確認する E2E テスト。

    Lambda の最大試行回数（maxReceiveCount）後にメッセージが DLQ に転送されることを
    確認するため、意図的に失敗するメッセージを送信する。
    """

    def test_invalid_s3_key_eventually_goes_to_dlq(
        self,
        sqs_client,
        ingest_queue_url,
        ingest_dlq_url,
    ):
        """
        存在しない S3 キーを指すメッセージは Lambda で失敗し、
        最大リトライ（maxReceiveCount=3）後に DLQ に転送される。

        注意: このテストは Lambda の Visibility Timeout と maxReceiveCount の設定に依存する。
        実際の環境では数分かかる場合がある。
        """
        # DLQ への転送は Lambda の Visibility Timeout + リトライ回数分の時間がかかる。
        # このテストは環境設定（Visibility Timeout）に依存するため、
        # CI では skip して手動確認とする。
        pytest.skip(
            "DLQ テストは Lambda の Visibility Timeout（maxReceiveCount=3 回）の経過後に確認が必要。"
            "インフラ検証時に手動で実行してください。"
        )
