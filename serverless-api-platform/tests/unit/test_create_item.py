# tests/unit/test_create_item.py
#
# create_item Lambda 関数のユニットテスト。
# moto を使用して DynamoDB をモックし、AWS への実際のリクエストなしにテストする。

import json
import os
import sys
import uuid
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws

# Lambda のシステムパスに shared モジュールを追加
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../src"))

# Lambda 環境変数のモック設定
os.environ["DYNAMODB_TABLE_NAME"] = "test-items"
os.environ["POWERTOOLS_SERVICE_NAME"] = "test-create-item"
os.environ["POWERTOOLS_METRICS_NAMESPACE"] = "TestNamespace"
os.environ["AWS_DEFAULT_REGION"] = "ap-northeast-1"


@pytest.fixture
def dynamodb_table():
    """テスト用 DynamoDB テーブルをモックで作成する。"""
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
        yield table


@pytest.fixture
def api_gw_event():
    """API Gateway プロキシイベントのベース fixture。"""
    def _make_event(body: dict, user_id: str = "test-user-123"):
        return {
            "httpMethod": "POST",
            "path": "/items",
            "requestContext": {
                "requestId": "test-request-id",
                "authorizer": {
                    "claims": {"sub": user_id}
                },
            },
            "body": json.dumps(body),
            "queryStringParameters": None,
            "pathParameters": None,
        }
    return _make_event


class TestCreateItem:
    def test_create_item_success(self, dynamodb_table, api_gw_event):
        """正常系: アイテムが正常に作成される。"""
        from create_item.handler import handler

        event = api_gw_event({"name": "テストアイテム", "description": "テスト説明"})
        response = handler(event, MagicMock())

        assert response["statusCode"] == 201
        body = json.loads(response["body"])
        assert body["success"] is True
        assert body["data"]["name"] == "テストアイテム"
        assert body["data"]["description"] == "テスト説明"
        assert body["data"]["status"] == "ACTIVE"
        assert "item_id" in body["data"]
        assert body["data"]["user_id"] == "test-user-123"

    def test_create_item_without_description(self, dynamodb_table, api_gw_event):
        """正常系: description なしでもアイテムが作成される。"""
        from create_item.handler import handler

        event = api_gw_event({"name": "名前のみアイテム"})
        response = handler(event, MagicMock())

        assert response["statusCode"] == 201
        body = json.loads(response["body"])
        assert body["success"] is True
        assert body["data"]["description"] is None

    def test_create_item_missing_name(self, dynamodb_table, api_gw_event):
        """異常系: name が指定されていない場合は 400 を返す。"""
        from create_item.handler import handler

        event = api_gw_event({"description": "名前なし"})
        response = handler(event, MagicMock())

        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert body["success"] is False
        assert body["error"]["code"] == "VALIDATION_ERROR"

    def test_create_item_empty_name(self, dynamodb_table, api_gw_event):
        """異常系: name が空白のみの場合は 400 を返す。"""
        from create_item.handler import handler

        event = api_gw_event({"name": "   "})
        response = handler(event, MagicMock())

        assert response["statusCode"] == 400

    def test_create_item_no_auth(self, dynamodb_table):
        """異常系: 認証情報がない場合は 401 を返す。"""
        from create_item.handler import handler

        event = {
            "httpMethod": "POST",
            "path": "/items",
            "requestContext": {"requestId": "test-request-id"},
            "body": json.dumps({"name": "テスト"}),
            "queryStringParameters": None,
        }
        response = handler(event, MagicMock())

        assert response["statusCode"] == 401
        body = json.loads(response["body"])
        assert body["error"]["code"] == "UNAUTHORIZED"
