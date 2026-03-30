# tests/unit/test_repository.py
#
# ItemRepository クラスのユニットテスト。
# moto で DynamoDB をモックして、リポジトリの CRUD 操作を検証する。

import os
import sys
import uuid
from datetime import datetime, timezone

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../src"))

os.environ["DYNAMODB_TABLE_NAME"] = "test-items"
os.environ["POWERTOOLS_SERVICE_NAME"] = "test-repository"
os.environ["AWS_DEFAULT_REGION"] = "ap-northeast-1"


@pytest.fixture
def table():
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")
        t = dynamodb.create_table(
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
        yield t


@pytest.fixture
def sample_item():
    """テスト用アイテムデータ。"""
    from shared.models import Item, ItemStatus

    now = datetime.now(timezone.utc).isoformat()
    return Item(
        item_id=str(uuid.uuid4()),
        user_id="user-123",
        name="テストアイテム",
        description="テスト説明",
        status=ItemStatus.ACTIVE,
        created_at=now,
        updated_at=now,
    )


class TestItemRepository:
    def test_create_and_get(self, table, sample_item):
        """正常系: アイテムを作成して取得できる。"""
        from shared.repository import ItemRepository

        repo = ItemRepository()
        repo.create(sample_item)

        retrieved = repo.get(sample_item.item_id)
        assert retrieved.item_id == sample_item.item_id
        assert retrieved.name == sample_item.name
        assert retrieved.user_id == sample_item.user_id

    def test_get_not_found(self, table):
        """異常系: 存在しないアイテムは ItemNotFoundError を発生させる。"""
        from shared.exceptions import ItemNotFoundError
        from shared.repository import ItemRepository

        repo = ItemRepository()
        with pytest.raises(ItemNotFoundError):
            repo.get("non-existent-id")

    def test_list_by_user(self, table, sample_item):
        """正常系: ユーザーのアイテム一覧を取得できる。"""
        from shared.repository import ItemRepository

        repo = ItemRepository()
        repo.create(sample_item)

        items, next_key = repo.list_by_user(sample_item.user_id)
        assert len(items) >= 1
        assert any(i.item_id == sample_item.item_id for i in items)

    def test_list_by_user_returns_only_own_items(self, table, sample_item):
        """正常系: 他ユーザーのアイテムは返されない。"""
        from shared.repository import ItemRepository

        repo = ItemRepository()
        repo.create(sample_item)

        items, _ = repo.list_by_user("other-user-456")
        assert all(i.user_id == "other-user-456" for i in items)

    def test_delete(self, table, sample_item):
        """正常系: アイテムを削除できる。"""
        from shared.exceptions import ItemNotFoundError
        from shared.repository import ItemRepository

        repo = ItemRepository()
        repo.create(sample_item)
        repo.delete(sample_item.item_id, sample_item.user_id)

        with pytest.raises(ItemNotFoundError):
            repo.get(sample_item.item_id)
