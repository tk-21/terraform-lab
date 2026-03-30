# tests/unit/test_list_items.py
#
# list_items Lambda 関数のユニットテスト。

import json
import os
import sys
import uuid
from datetime import datetime, timezone
from unittest.mock import MagicMock

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../src"))

os.environ["DYNAMODB_TABLE_NAME"] = "test-items"
os.environ["POWERTOOLS_SERVICE_NAME"] = "test-list-items"
os.environ["POWERTOOLS_METRICS_NAMESPACE"] = "TestNamespace"
os.environ["AWS_DEFAULT_REGION"] = "ap-northeast-1"


@pytest.fixture
def dynamodb_table():
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")
        table = dynamodb.create_table(
            TableName="test-items",
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

        # テスト用データの投入
        user_id = "test-user-123"
        for i in range(3):
            item_id = str(uuid.uuid4())
            now = datetime.now(timezone.utc).isoformat()
            table.put_item(
                Item={
                    "PK": f"ITEM#{item_id}",
                    "SK": f"ITEM#{item_id}",
                    "item_id": item_id,
                    "user_id": user_id,
                    "name": f"テストアイテム {i+1}",
                    "status": "ACTIVE",
                    "created_at": now,
                    "updated_at": now,
                }
            )

        yield table


class TestListItems:
    def test_list_items_success(self, dynamodb_table):
        """正常系: アイテム一覧が返される。"""
        from list_items.handler import handler

        event = {
            "httpMethod": "GET",
            "path": "/items",
            "requestContext": {
                "requestId": "test-request-id",
                "authorizer": {"claims": {"sub": "test-user-123"}},
            },
            "queryStringParameters": None,
            "pathParameters": None,
        }
        response = handler(event, MagicMock())

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["success"] is True
        assert "data" in body
        assert "pagination" in body
        assert isinstance(body["data"], list)

    def test_list_items_empty(self, dynamodb_table):
        """正常系: アイテムがないユーザーは空リストを返す。"""
        from list_items.handler import handler

        event = {
            "httpMethod": "GET",
            "path": "/items",
            "requestContext": {
                "requestId": "test-request-id",
                "authorizer": {"claims": {"sub": "no-items-user"}},
            },
            "queryStringParameters": None,
        }
        response = handler(event, MagicMock())

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["data"] == []
        assert body["pagination"]["has_more"] is False

    def test_list_items_with_limit(self, dynamodb_table):
        """正常系: limit パラメータが機能する。"""
        from list_items.handler import handler

        event = {
            "httpMethod": "GET",
            "path": "/items",
            "requestContext": {
                "requestId": "test-request-id",
                "authorizer": {"claims": {"sub": "test-user-123"}},
            },
            "queryStringParameters": {"limit": "1"},
        }
        response = handler(event, MagicMock())

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert len(body["data"]) <= 1
