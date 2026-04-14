"""pytest 共通フィクスチャ。

moto で AWS サービスをモックし、各テストが独立した環境で実行されるようにする。
"""
import os

import boto3
import pytest
from moto import mock_aws

# テスト実行環境では X-Ray の UDP ソケットを開かない。
# fixture 実行前に Lambda モジュールが import されるケースがあるため、
# トップレベルで設定して初期化時の Tracer を無効化する。
os.environ.setdefault("POWERTOOLS_TRACE_DISABLED", "1")


# テスト用の環境変数をデフォルト設定
@pytest.fixture(autouse=True)
def aws_credentials():
    """moto が実際の AWS に接続しないようにダミー認証情報をセット。"""
    os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
    os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
    os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
    os.environ.setdefault("AWS_SESSION_TOKEN", "testing")
    os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
    os.environ.setdefault("ENVIRONMENT", "test")
    os.environ.setdefault("POWERTOOLS_SERVICE_NAME", "sep-test")
    os.environ.setdefault("POWERTOOLS_METRICS_NAMESPACE", "ServerlessEventPipeline")
    # Powertools のログ出力をテスト中は抑制
    os.environ.setdefault("POWERTOOLS_LOG_LEVEL", "WARNING")


@pytest.fixture
def dynamodb_table(aws_credentials):
    """sep-test-events DynamoDB テーブルを moto で作成するフィクスチャ。"""
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")
        table = dynamodb.create_table(
            TableName="sep-test-events",
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
        # TTL 設定（moto ではシミュレートのみ）
        dynamodb.meta.client.update_time_to_live(
            TableName="sep-test-events",
            TimeToLiveSpecification={"Enabled": True, "AttributeName": "expires_at"},
        )
        yield table


@pytest.fixture
def sqs_queues(aws_credentials):
    """transform キューと DLQ を moto で作成するフィクスチャ。"""
    with mock_aws():
        sqs = boto3.client("sqs", region_name="ap-northeast-1")

        # DLQ を先に作成（メインキューが参照するため）
        dlq_response = sqs.create_queue(QueueName="sep-test-transform-dlq")
        dlq_url = dlq_response["QueueUrl"]
        dlq_attrs = sqs.get_queue_attributes(
            QueueUrl=dlq_url, AttributeNames=["QueueArn"]
        )
        dlq_arn = dlq_attrs["Attributes"]["QueueArn"]

        # メインキュー（DLQ 付き）
        queue_response = sqs.create_queue(
            QueueName="sep-test-transform-queue",
            Attributes={
                "RedrivePolicy": f'{{"deadLetterTargetArn":"{dlq_arn}","maxReceiveCount":"3"}}',
                # Lambda タイムアウト(30s) x 6 = 180s
                "VisibilityTimeout": "180",
            },
        )

        yield {
            "queue_url": queue_response["QueueUrl"],
            "dlq_url": dlq_url,
            "dlq_arn": dlq_arn,
        }


@pytest.fixture
def s3_buckets(aws_credentials):
    """アーカイブ用 S3 バケットを moto で作成するフィクスチャ。"""
    with mock_aws():
        s3 = boto3.client("s3", region_name="ap-northeast-1")
        account_id = "123456789012"

        buckets = {
            "archive": f"sep-test-archive-{account_id}",
            "dead_letter": f"sep-test-dead-letter-archive-{account_id}",
        }

        for bucket_name in buckets.values():
            s3.create_bucket(
                Bucket=bucket_name,
                CreateBucketConfiguration={"LocationConstraint": "ap-northeast-1"},
            )

        yield buckets
