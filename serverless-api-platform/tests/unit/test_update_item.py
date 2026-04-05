# tests/unit/test_update_item.py
#
# PUT /items/{id} (update_item Lambda) のユニットテスト。
#
# 検証観点:
#   - 正常更新（name・description・status 各フィールド）
#   - 一部フィールドのみ更新（部分更新 / PATCH 的挙動）
#   - 他ユーザーのアイテムへの更新で 403 Forbidden
#   - 存在しないアイテムへの更新で 404 Not Found
#   - 更新フィールドが空の場合 400 Validation Error

import json
import time

import pytest

# conftest.py で sys.path・os.environ 設定済み
from conftest import make_event


ITEM_ID = "test-item-id-for-update"
OWNER_USER = "owner-user-123"
OTHER_USER = "other-user-456"


@pytest.fixture
def seeded_table(dynamodb_table):
    """
    update_item テスト用の事前作成アイテム。
    OWNER_USER が所有するアイテムを DynamoDB に書き込む。
    """
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc).isoformat()
    dynamodb_table.put_item(
        Item={
            "PK": f"ITEM#{ITEM_ID}",
            "SK": f"ITEM#{ITEM_ID}",
            "item_id": ITEM_ID,
            "user_id": OWNER_USER,
            "name": "元のアイテム名",
            "description": "元の説明",
            "status": "ACTIVE",
            "created_at": now,
            "updated_at": now,
        }
    )
    return dynamodb_table


def _update_event(body: dict, user_id: str = OWNER_USER, item_id: str = ITEM_ID) -> dict:
    """PUT /items/{id} のイベントを生成するヘルパー。"""
    return make_event("PUT", f"/items/{item_id}", body=body, user_id=user_id)


class TestUpdateItemSuccess:
    """正常更新のテスト。"""

    def test_update_name_only(self, seeded_table, mock_context):
        """正常系: name だけ更新できる（description・status は変わらない）。"""
        from update_item.handler import handler

        event = _update_event({"name": "更新後の名前"})
        response = handler(event, mock_context)

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["success"] is True
        assert body["data"]["name"] == "更新後の名前"
        assert body["data"]["item_id"] == ITEM_ID

    def test_update_description_only(self, seeded_table, mock_context):
        """正常系: description だけ更新できる（部分更新）。"""
        from update_item.handler import handler

        event = _update_event({"description": "新しい説明"})
        response = handler(event, mock_context)

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["data"]["description"] == "新しい説明"
        # name は変更されていない
        assert body["data"]["name"] == "元のアイテム名"

    def test_update_status_to_archived(self, seeded_table, mock_context):
        """
        正常系: status=ARCHIVED への変更で expires_at が設定される。
        論理削除フローのトリガーとなる重要な挙動。
        """
        from update_item.handler import handler

        before_ts = int(time.time())
        event = _update_event({"status": "ARCHIVED"})
        response = handler(event, mock_context)
        after_ts = int(time.time())

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["data"]["status"] == "ARCHIVED"
        # expires_at は30日後前後
        expires_at = body["data"]["expires_at"]
        assert expires_at is not None
        expected_min = before_ts + 30 * 24 * 3600 - 10
        expected_max = after_ts + 30 * 24 * 3600 + 10
        assert expected_min <= expires_at <= expected_max

    def test_update_multiple_fields(self, seeded_table, mock_context):
        """正常系: name・description を同時に更新できる。"""
        from update_item.handler import handler

        event = _update_event({"name": "複数更新", "description": "同時に更新"})
        response = handler(event, mock_context)

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["data"]["name"] == "複数更新"
        assert body["data"]["description"] == "同時に更新"

    def test_update_refreshes_updated_at(self, seeded_table, mock_context):
        """正常系: 更新後の updated_at が最新時刻になる。"""
        from update_item.handler import handler

        # 元の updated_at を取得
        raw = seeded_table.get_item(
            Key={"PK": f"ITEM#{ITEM_ID}", "SK": f"ITEM#{ITEM_ID}"}
        )["Item"]
        original_updated_at = raw["updated_at"]

        event = _update_event({"name": "updated_at 確認"})
        response = handler(event, mock_context)

        body = json.loads(response["body"])
        assert body["data"]["updated_at"] >= original_updated_at


class TestUpdateItemErrors:
    """エラーケースのテスト。"""

    def test_update_other_users_item_returns_403(self, seeded_table, mock_context):
        """
        異常系: 他ユーザーのアイテムを更新しようとすると 403 FORBIDDEN。
        ハンドラーが get() → 所有者チェック → ForbiddenError の順で処理するため
        404 ではなく 403 が返る（CLAUDE.md 設計コメント参照）。
        """
        from update_item.handler import handler

        event = _update_event({"name": "乗っ取り"}, user_id=OTHER_USER)
        response = handler(event, mock_context)

        assert response["statusCode"] == 403
        body = json.loads(response["body"])
        assert body["success"] is False
        assert body["error"]["code"] == "FORBIDDEN"

    def test_update_nonexistent_item_returns_404(self, seeded_table, mock_context):
        """異常系: 存在しない item_id を更新すると 404 ITEM_NOT_FOUND。"""
        from update_item.handler import handler

        event = _update_event({"name": "存在しない"}, item_id="ghost-item-id")
        response = handler(event, mock_context)

        assert response["statusCode"] == 404
        body = json.loads(response["body"])
        assert body["success"] is False
        assert body["error"]["code"] == "ITEM_NOT_FOUND"

    def test_update_empty_body_returns_400(self, seeded_table, mock_context):
        """
        異常系: 更新フィールドが1つもない場合は 400 VALIDATION_ERROR。
        ItemUpdate の model_validator で "少なくとも1フィールド必須" が検証される。
        """
        from update_item.handler import handler

        event = _update_event({})
        response = handler(event, mock_context)

        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert body["error"]["code"] == "VALIDATION_ERROR"

    def test_update_invalid_status_returns_400(self, seeded_table, mock_context):
        """異常系: status に許容値以外を指定すると 400。"""
        from update_item.handler import handler

        event = _update_event({"status": "DELETED"})  # ACTIVE / ARCHIVED 以外
        response = handler(event, mock_context)

        assert response["statusCode"] == 400

    def test_update_name_too_long_returns_400(self, seeded_table, mock_context):
        """異常系: name が 101 文字以上は 400。"""
        from update_item.handler import handler

        event = _update_event({"name": "あ" * 101})
        response = handler(event, mock_context)

        assert response["statusCode"] == 400

    def test_update_no_auth_returns_401(self, seeded_table, mock_context):
        """異常系: 認証情報がない場合は 401 UNAUTHORIZED。"""
        from update_item.handler import handler

        event = make_event(
            "PUT", f"/items/{ITEM_ID}", body={"name": "認証なし"}, include_auth=False
        )
        response = handler(event, mock_context)

        assert response["statusCode"] == 401
        body = json.loads(response["body"])
        assert body["error"]["code"] == "UNAUTHORIZED"
