# tests/unit/conftest.py
#
# Unit テスト共通 fixtures。
# moto で DynamoDB をモックし、各テストに独立した環境を提供する。
#
# 重要: os.environ の設定はハンドラーモジュールのインポートより前に行う必要がある。
# conftest.py は pytest が最初にロードするため、ここに集約する。

import base64
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from unittest.mock import MagicMock

import boto3
import pytest
from moto import mock_aws

# src/ を sys.path に追加（handler / shared をインポート可能にする）
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../src"))

# Lambda 環境変数（ハンドラーモジュールのインポート前に設定する）
os.environ.setdefault("DYNAMODB_TABLE_NAME", "test-items")
os.environ.setdefault("POWERTOOLS_SERVICE_NAME", "test")
os.environ.setdefault("POWERTOOLS_METRICS_NAMESPACE", "TestNamespace")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
# moto が使用するダミー認証情報（実際の AWS には接続しない）
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")
# X-Ray トレースを無効化（テスト環境では不要）
os.environ.setdefault("POWERTOOLS_TRACE_DISABLED", "true")

TABLE_NAME = "test-items"


def _create_table(dynamodb_resource):
    """
    Single Table Design に従った DynamoDB テーブルと GSI を作成する。
    実際の Terraform 定義（modules/dynamodb/main.tf）と同一の構造。
    """
    return dynamodb_resource.create_table(
        TableName=TABLE_NAME,
        KeySchema=[
            {"AttributeName": "PK", "KeyType": "HASH"},
            {"AttributeName": "SK", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "PK", "AttributeType": "S"},
            {"AttributeName": "SK", "AttributeType": "S"},
            {"AttributeName": "user_id", "AttributeType": "S"},
            {"AttributeName": "created_at", "AttributeType": "S"},
        ],
        GlobalSecondaryIndexes=[
            {
                "IndexName": "user-index",
                "KeySchema": [
                    {"AttributeName": "user_id", "KeyType": "HASH"},
                    {"AttributeName": "created_at", "KeyType": "RANGE"},
                ],
                "Projection": {"ProjectionType": "ALL"},
            }
        ],
        BillingMode="PAY_PER_REQUEST",
    )


@pytest.fixture
def dynamodb_table():
    """
    各テスト関数に対して新しい moto DynamoDB テーブルを提供する。
    mock_aws() コンテキスト内で yield するため、テスト終了後に状態がリセットされる。
    """
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")
        table = _create_table(dynamodb)
        yield table


@pytest.fixture
def sample_item():
    """
    テスト用 ItemResponse オブジェクト。
    repository のテストで直接使用する。
    """
    from shared.models import ItemResponse

    now = datetime.now(timezone.utc).isoformat()
    return ItemResponse(
        item_id=str(uuid.uuid4()),
        user_id="test-user-123",
        name="テストアイテム",
        description="テスト用の説明",
        status="ACTIVE",
        created_at=now,
        updated_at=now,
        expires_at=None,
    )


@pytest.fixture
def seeded_item(dynamodb_table):
    """
    DynamoDB に書き込み済みのアイテムを返す。
    handler テストで「既存アイテムへの操作」を検証するときに使用する。
    """
    from shared.repository import ItemRepository
    from shared.models import ItemResponse

    now = datetime.now(timezone.utc).isoformat()
    item = ItemResponse(
        item_id="fixed-item-id-0001",
        user_id="test-user-123",
        name="既存アイテム",
        description="seeded 用の説明",
        status="ACTIVE",
        created_at=now,
        updated_at=now,
        expires_at=None,
    )
    repo = ItemRepository()
    repo.create(item)
    return item


def make_event(
    method: str,
    path: str,
    body: dict | None = None,
    user_id: str = "test-user-123",
    query_params: dict | None = None,
    include_auth: bool = True,
) -> dict:
    """
    API Gateway プロキシ統合イベント（v1）を生成するファクトリ。
    APIGatewayRestResolver が期待する最小限のフィールドを含む。
    """
    authorizer = {"claims": {"sub": user_id}} if include_auth else {}
    return {
        "httpMethod": method,
        "path": path,
        "requestContext": {
            "requestId": f"test-req-{uuid.uuid4().hex[:8]}",
            "authorizer": authorizer,
        },
        "body": json.dumps(body) if body is not None else None,
        "queryStringParameters": query_params,
        "pathParameters": None,
        "multiValueQueryStringParameters": None,
        "headers": {"Content-Type": "application/json"},
    }


@pytest.fixture
def mock_context():
    """Lambda Context のモック。handler(event, context) の context 引数に使用する。"""
    ctx = MagicMock()
    ctx.aws_request_id = "test-lambda-request-id"
    ctx.function_name = "test-function"
    return ctx
