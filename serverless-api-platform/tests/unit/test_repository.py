# tests/unit/test_repository.py
#
# ItemRepository クラスのユニットテスト。
# @mock_aws (moto v4) で DynamoDB をモックし、外部 AWS への通信なしで検証する。
#
# テスト対象メソッド:
#   create    : 正常系・重複エラー（ConditionalCheckFailedException）
#   get       : 存在する場合・存在しない場合（ItemNotFoundError）
#   update    : 正常系・対象なし（ItemNotFoundError）
#   delete    : 論理削除確認（status=ARCHIVED、expires_at 設定）
#   list_by_user: ページネーション（LastEvaluatedKey → Base64 cursor）

import base64
import json
import time
import uuid
from datetime import datetime, timezone

import pytest

# conftest.py で sys.path と os.environ が設定済み
from shared.exceptions import ItemAlreadyExistsError, ItemNotFoundError
from shared.models import ItemResponse
from shared.repository import ItemRepository


def _make_item(
    item_id: str | None = None,
    user_id: str = "user-test",
    name: str = "テスト",
    description: str | None = None,
    created_at: str | None = None,
) -> ItemResponse:
    """テスト用 ItemResponse を生成するヘルパー。"""
    now = created_at or datetime.now(timezone.utc).isoformat()
    return ItemResponse(
        item_id=item_id or str(uuid.uuid4()),
        user_id=user_id,
        name=name,
        description=description,
        status="ACTIVE",
        created_at=now,
        updated_at=now,
        expires_at=None,
    )


class TestCreate:
    """ItemRepository.create() のテスト。"""

    def test_create_success(self, dynamodb_table):
        """正常系: アイテムを作成して DynamoDB に書き込まれることを確認する。"""
        repo = ItemRepository()
        item = _make_item()

        result = repo.create(item)

        # 返却値は同じ ItemResponse
        assert result.item_id == item.item_id
        assert result.name == item.name

        # DynamoDB から直接取得してスキーマを検証
        raw = dynamodb_table.get_item(
            Key={"PK": f"ITEM#{item.item_id}", "SK": f"ITEM#{item.item_id}"}
        )["Item"]
        assert raw["PK"] == f"ITEM#{item.item_id}"
        assert raw["SK"] == f"ITEM#{item.item_id}"
        assert raw["item_id"] == item.item_id
        assert raw["user_id"] == item.user_id
        assert raw["name"] == item.name
        assert raw["status"] == "ACTIVE"
        assert "created_at" in raw
        assert "updated_at" in raw

    def test_create_with_description(self, dynamodb_table):
        """正常系: description ありのアイテムが正しく保存される。"""
        repo = ItemRepository()
        item = _make_item(description="詳細説明テスト")

        repo.create(item)

        raw = dynamodb_table.get_item(
            Key={"PK": f"ITEM#{item.item_id}", "SK": f"ITEM#{item.item_id}"}
        )["Item"]
        assert raw["description"] == "詳細説明テスト"

    def test_create_duplicate_raises_error(self, dynamodb_table):
        """
        異常系: 同一 item_id を2回作成すると ItemAlreadyExistsError が発生する。
        DynamoDB の ConditionExpression "attribute_not_exists(PK)" が失敗する。
        """
        repo = ItemRepository()
        item = _make_item(item_id="duplicate-id")

        repo.create(item)

        with pytest.raises(ItemAlreadyExistsError) as exc_info:
            repo.create(item)

        assert exc_info.value.item_id == "duplicate-id"

    def test_create_without_description_no_null_attribute(self, dynamodb_table):
        """正常系: description なしのアイテムでは DynamoDB に description 属性が存在しない。"""
        repo = ItemRepository()
        item = _make_item(description=None)

        repo.create(item)

        raw = dynamodb_table.get_item(
            Key={"PK": f"ITEM#{item.item_id}", "SK": f"ITEM#{item.item_id}"}
        )["Item"]
        # None フィールドは DynamoDB に書き込まない設計（CLAUDE.md 方針）
        assert "description" not in raw


class TestGet:
    """ItemRepository.get() のテスト。"""

    def test_get_existing_item(self, dynamodb_table):
        """正常系: 存在するアイテムを正しく取得できる。"""
        repo = ItemRepository()
        item = _make_item(name="取得テスト", description="説明")
        repo.create(item)

        result = repo.get(item.item_id)

        assert result.item_id == item.item_id
        assert result.name == "取得テスト"
        assert result.description == "説明"
        assert result.user_id == item.user_id
        assert result.status == "ACTIVE"

    def test_get_not_found_raises_error(self, dynamodb_table):
        """異常系: 存在しない item_id を取得すると ItemNotFoundError が発生する。"""
        repo = ItemRepository()

        with pytest.raises(ItemNotFoundError) as exc_info:
            repo.get("non-existent-id")

        assert exc_info.value.item_id == "non-existent-id"

    def test_get_returns_archived_item(self, dynamodb_table):
        """
        正常系: 論理削除済み（ARCHIVED）のアイテムも取得できる。
        get() は status フィルタを行わない設計（CLAUDE.md 論理削除方針）。
        """
        repo = ItemRepository()
        item = _make_item()
        repo.create(item)
        repo.delete(item.item_id)  # 論理削除

        # 論理削除後も get() で取得可能（status=ARCHIVED）
        result = repo.get(item.item_id)
        assert result.status == "ARCHIVED"
        assert result.expires_at is not None


class TestUpdate:
    """ItemRepository.update() のテスト。"""

    def test_update_name_success(self, dynamodb_table):
        """正常系: name フィールドを更新できる。"""
        repo = ItemRepository()
        item = _make_item(name="元の名前")
        repo.create(item)

        result = repo.update(item_id=item.item_id, name="更新後の名前")

        assert result.name == "更新後の名前"
        assert result.item_id == item.item_id
        # updated_at が更新されている
        assert result.updated_at >= item.updated_at

    def test_update_description_only(self, dynamodb_table):
        """正常系: description のみを更新できる（部分更新）。"""
        repo = ItemRepository()
        item = _make_item(name="固定名前", description="旧説明")
        repo.create(item)

        result = repo.update(item_id=item.item_id, description="新説明")

        assert result.description == "新説明"
        # name は変更されていない
        assert result.name == "固定名前"

    def test_update_status_to_archived_sets_expires_at(self, dynamodb_table):
        """
        正常系: status=ARCHIVED への更新で expires_at（30日後）が設定される。
        DynamoDB TTL 自動削除のトリガーとなる重要な検証。
        """
        repo = ItemRepository()
        item = _make_item()
        repo.create(item)

        before_ts = int(time.time())
        result = repo.update(item_id=item.item_id, status="ARCHIVED")
        after_ts = int(time.time())

        assert result.status == "ARCHIVED"
        assert result.expires_at is not None
        # expires_at は「現在 + 30日」前後になるはず（±10秒の余裕）
        expected_min = before_ts + 30 * 24 * 3600 - 10
        expected_max = after_ts + 30 * 24 * 3600 + 10
        assert expected_min <= result.expires_at <= expected_max

    def test_update_not_found_raises_error(self, dynamodb_table):
        """異常系: 存在しないアイテムを更新すると ItemNotFoundError が発生する。"""
        repo = ItemRepository()

        with pytest.raises(ItemNotFoundError) as exc_info:
            repo.update(item_id="ghost-item-id", name="幻のアイテム")

        assert exc_info.value.item_id == "ghost-item-id"

    def test_update_multiple_fields_at_once(self, dynamodb_table):
        """正常系: name・description・status を同時に更新できる。"""
        repo = ItemRepository()
        item = _make_item(name="古い名前", description="古い説明")
        repo.create(item)

        result = repo.update(
            item_id=item.item_id,
            name="新しい名前",
            description="新しい説明",
            status="ARCHIVED",
        )

        assert result.name == "新しい名前"
        assert result.description == "新しい説明"
        assert result.status == "ARCHIVED"
        assert result.expires_at is not None


class TestDelete:
    """ItemRepository.delete() のテスト。"""

    def test_delete_is_logical_not_physical(self, dynamodb_table):
        """
        重要: delete() は論理削除であり、DynamoDB レコードは削除されない。
        status=ARCHIVED・expires_at 設定を確認する（CLAUDE.md 設計方針）。
        """
        repo = ItemRepository()
        item = _make_item()
        repo.create(item)

        before_ts = int(time.time())
        repo.delete(item.item_id)
        after_ts = int(time.time())

        # DynamoDB から直接取得してレコードが残っていることを確認
        raw = dynamodb_table.get_item(
            Key={"PK": f"ITEM#{item.item_id}", "SK": f"ITEM#{item.item_id}"}
        )["Item"]

        assert raw["status"] == "ARCHIVED"
        # expires_at は「現在 + 30日」前後
        expires_at = int(raw["expires_at"])
        expected_min = before_ts + 30 * 24 * 3600 - 10
        expected_max = after_ts + 30 * 24 * 3600 + 10
        assert expected_min <= expires_at <= expected_max

    def test_delete_item_still_retrievable_via_get(self, dynamodb_table):
        """
        論理削除後も get() でアイテムを取得できる（ARCHIVED ステータス）。
        物理削除ではないため、監査ログ・PITR 復元が可能。
        """
        repo = ItemRepository()
        item = _make_item()
        repo.create(item)
        repo.delete(item.item_id)

        # 論理削除後も ItemNotFoundError は発生しない
        result = repo.get(item.item_id)
        assert result.status == "ARCHIVED"

    def test_delete_not_found_raises_error(self, dynamodb_table):
        """異常系: 存在しないアイテムを削除すると ItemNotFoundError が発生する。"""
        repo = ItemRepository()

        with pytest.raises(ItemNotFoundError):
            repo.delete("non-existent-item")

    def test_delete_updates_updated_at(self, dynamodb_table):
        """正常系: 論理削除時に updated_at が更新される。"""
        repo = ItemRepository()
        item = _make_item()
        repo.create(item)
        original_updated_at = item.updated_at

        repo.delete(item.item_id)

        raw = dynamodb_table.get_item(
            Key={"PK": f"ITEM#{item.item_id}", "SK": f"ITEM#{item.item_id}"}
        )["Item"]
        assert raw["updated_at"] >= original_updated_at


class TestListByUser:
    """ItemRepository.list_by_user() のテスト。"""

    def _seed_items(self, repo, user_id: str, count: int) -> list[ItemResponse]:
        """指定ユーザーのアイテムを count 件 DynamoDB に書き込む。"""
        items = []
        for i in range(count):
            # created_at を意図的にずらして GSI のソート順を確定させる
            created_at = f"2024-01-{i+1:02d}T00:00:00+00:00"
            item = _make_item(user_id=user_id, name=f"アイテム {i+1}", created_at=created_at)
            repo.create(item)
            items.append(item)
        return items

    def test_list_returns_users_items(self, dynamodb_table):
        """正常系: 指定ユーザーのアイテムのみが返される。"""
        repo = ItemRepository()
        self._seed_items(repo, "user-A", 3)
        self._seed_items(repo, "user-B", 2)

        items, next_key = repo.list_by_user("user-A")

        assert len(items) == 3
        assert all(i.user_id == "user-A" for i in items)

    def test_list_empty_for_unknown_user(self, dynamodb_table):
        """正常系: アイテムを持たないユーザーは空リストを返す。"""
        repo = ItemRepository()

        items, next_key = repo.list_by_user("no-items-user")

        assert items == []
        assert next_key is None

    def test_list_pagination_next_key_exists(self, dynamodb_table):
        """
        正常系: limit より多いアイテムが存在する場合、next_key（LastEvaluatedKey）が返る。
        next_key は DynamoDB の ExclusiveStartKey 形式の dict。
        """
        repo = ItemRepository()
        self._seed_items(repo, "user-paginate", 5)

        items, next_key = repo.list_by_user("user-paginate", limit=2)

        assert len(items) == 2
        assert next_key is not None
        # next_key は DynamoDB ExclusiveStartKey 形式（GSI 含むため複数キー）
        assert "PK" in next_key or "user_id" in next_key

    def test_list_pagination_cursor_can_be_base64_encoded(self, dynamodb_table):
        """
        ページネーション: next_key を Base64 エンコードして cursor にできる。
        handler 層での cursor 変換ロジックを repository 単体で検証する。
        """
        repo = ItemRepository()
        self._seed_items(repo, "user-cursor", 4)

        _, next_key = repo.list_by_user("user-cursor", limit=2)
        assert next_key is not None

        # handler 層と同じ変換: Base64(JSON(ExclusiveStartKey))
        cursor = base64.b64encode(json.dumps(next_key).encode()).decode()
        decoded_key = json.loads(base64.b64decode(cursor).decode())

        # デコードした key を使って次ページを取得できる
        page2_items, _ = repo.list_by_user("user-cursor", limit=2, last_evaluated_key=decoded_key)
        assert len(page2_items) == 2

    def test_list_all_pages_cover_all_items(self, dynamodb_table):
        """
        ページネーション: 全ページを取得すると全アイテムを網羅できる。
        """
        repo = ItemRepository()
        self._seed_items(repo, "user-full-scan", 5)

        collected = []
        last_key = None
        while True:
            items, last_key = repo.list_by_user(
                "user-full-scan", limit=2, last_evaluated_key=last_key
            )
            collected.extend(items)
            if last_key is None:
                break

        assert len(collected) == 5

    def test_list_no_next_key_when_all_fit(self, dynamodb_table):
        """正常系: 全アイテムが limit 以内に収まる場合、next_key は None。"""
        repo = ItemRepository()
        self._seed_items(repo, "user-small", 3)

        items, next_key = repo.list_by_user("user-small", limit=10)

        assert len(items) == 3
        assert next_key is None
