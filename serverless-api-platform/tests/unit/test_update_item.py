# tests/unit/test_update_item.py
#
# update_item Lambda 関数のユニットテスト。

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
os.environ["POWERTOOLS_SERVICE_NAME"] = "test-update-item"
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

        # テストアイテムを事前に作成
        item_id = "test-item-id"
        now = datetime.now(timezone.utc).isoformat()
        table.put_item(
            Item={
                "PK": f"ITEM#{item_id}",
                "SK": f"ITEM#{item_id}",
                "item_id": item_id,
                "user_id": "test-user-123",
                "name": "元のアイテム名",
                "status": "ACTIVE",
                "created_at": now,
                "updated_at": now,
            }
        )

        yield table


class TestUpdateItem:
    def test_update_name_success(self, dynamodb_table):
        """正常系: アイテム名を更新できる。"""
        from update_item.handler import handler

        event = {
            "httpMethod": "PUT",
            "path": "/items/test-item-id",
            "requestContext": {
                "requestId": "test-request-id",
                "authorizer": {"claims": {"sub": "test-user-123"}},
            },
            "pathParameters": {"id": "test-item-id"},
            "body": json.dumps({"name": "更新後のアイテム名"}),
            "queryStringParameters": None,
        }
        response = handler(event, MagicMock())

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["success"] is True
        assert body["data"]["name"] == "更新後のアイテム名"

    def test_update_not_found(self, dynamodb_table):
        """異常系: 存在しないアイテムは 404 を返す。"""
        from update_item.handler import handler

        event = {
            "httpMethod": "PUT",
            "path": "/items/non-existent-id",
            "requestContext": {
                "requestId": "test-request-id",
                "authorizer": {"claims": {"sub": "test-user-123"}},
            },
            "pathParameters": {"id": "non-existent-id"},
            "body": json.dumps({"name": "更新後"}),
            "queryStringParameters": None,
        }
        response = handler(event, MagicMock())

        assert response["statusCode"] == 404

    def test_update_other_users_item_forbidden(self, dynamodb_table):
        """異常系: 他ユーザーのアイテムは更新できない（403）。"""
        from update_item.handler import handler

        event = {
            "httpMethod": "PUT",
            "path": "/items/test-item-id",
            "requestContext": {
                "requestId": "test-request-id",
                "authorizer": {"claims": {"sub": "other-user-456"}},
            },
            "pathParameters": {"id": "test-item-id"},
            "body": json.dumps({"name": "不正な更新"}),
            "queryStringParameters": None,
        }
        response = handler(event, MagicMock())

        assert response["statusCode"] in [403, 404]

    def test_update_empty_body(self, dynamodb_table):
        """異常系: 更新フィールドが何もない場合は 400 を返す。"""
        from update_item.handler import handler

        event = {
            "httpMethod": "PUT",
            "path": "/items/test-item-id",
            "requestContext": {
                "requestId": "test-request-id",
                "authorizer": {"claims": {"sub": "test-user-123"}},
            },
            "pathParameters": {"id": "test-item-id"},
            "body": json.dumps({}),
            "queryStringParameters": None,
        }
        response = handler(event, MagicMock())

        assert response["statusCode"] == 400
