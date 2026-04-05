# tests/unit/test_list_items.py
#
# GET /items (list_items Lambda) のユニットテスト。
#
# 検証観点:
#   - 空リスト・複数件・ページネーション有りの各ケース
#   - limit パラメータの境界値テスト
#   - cursor が不正な場合は最初のページを返す（エラーにしない設計）
#   - レスポンス形式（pagination オブジェクト）の検証

import base64
import json
import uuid
from datetime import datetime, timezone

import pytest

# conftest.py で sys.path・os.environ 設定済み
from conftest import make_event


def _seed_user_items(dynamodb_table, user_id: str, count: int) -> list[str]:
    """
    指定ユーザーの DynamoDB アイテムを直接書き込む。
    created_at を意図的にずらして GSI（user-index）の ScanIndexForward=False が機能するようにする。
    """
    item_ids = []
    for i in range(count):
        item_id = str(uuid.uuid4())
        now = f"2024-{i+1:02d}-01T00:00:00+00:00"
        dynamodb_table.put_item(
            Item={
                "PK": f"ITEM#{item_id}",
                "SK": f"ITEM#{item_id}",
                "item_id": item_id,
                "user_id": user_id,
                "name": f"アイテム {i+1}",
                "status": "ACTIVE",
                "created_at": now,
                "updated_at": now,
            }
        )
        item_ids.append(item_id)
    return item_ids


class TestListItemsBasic:
    """基本的な一覧取得のテスト。"""

    def test_list_empty(self, dynamodb_table, mock_context):
        """正常系: アイテムがないユーザーは空リストと has_more=false を返す。"""
        from list_items.handler import handler

        event = make_event("GET", "/items", user_id="empty-user")
        response = handler(event, mock_context)

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["success"] is True
        assert body["data"] == []
        assert body["pagination"]["has_more"] is False
        assert body["pagination"]["next_cursor"] is None
        assert body["pagination"]["count"] == 0

    def test_list_multiple_items(self, dynamodb_table, mock_context):
        """正常系: 複数件のアイテムが返される。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "multi-user", 3)
        event = make_event("GET", "/items", user_id="multi-user")
        response = handler(event, mock_context)

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert len(body["data"]) == 3
        assert body["pagination"]["count"] == 3
        # 各アイテムが必要なフィールドを持つ
        for item in body["data"]:
            assert "item_id" in item
            assert "name" in item
            assert "status" in item
            assert "created_at" in item

    def test_list_only_returns_own_items(self, dynamodb_table, mock_context):
        """正常系: 他ユーザーのアイテムは一覧に含まれない。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "user-a", 2)
        _seed_user_items(dynamodb_table, "user-b", 3)

        event = make_event("GET", "/items", user_id="user-a")
        response = handler(event, mock_context)

        body = json.loads(response["body"])
        assert len(body["data"]) == 2
        assert all(item["user_id"] == "user-a" for item in body["data"])

    def test_list_response_has_meta(self, dynamodb_table, mock_context):
        """正常系: レスポンスに meta（request_id・timestamp）が含まれる。"""
        from list_items.handler import handler

        event = make_event("GET", "/items")
        response = handler(event, mock_context)

        body = json.loads(response["body"])
        assert "meta" in body
        assert "request_id" in body["meta"]
        assert "timestamp" in body["meta"]

    def test_list_no_auth_returns_401(self, dynamodb_table, mock_context):
        """異常系: 認証情報がない場合は 401 を返す。"""
        from list_items.handler import handler

        event = make_event("GET", "/items", include_auth=False)
        response = handler(event, mock_context)

        assert response["statusCode"] == 401
        body = json.loads(response["body"])
        assert body["error"]["code"] == "UNAUTHORIZED"


class TestListItemsPagination:
    """ページネーション機能のテスト。"""

    def test_pagination_with_limit(self, dynamodb_table, mock_context):
        """正常系: limit=1 で 3 件あれば has_more=true・next_cursor が返る。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "page-user", 3)

        event = make_event("GET", "/items", user_id="page-user", query_params={"limit": "1"})
        response = handler(event, mock_context)

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert len(body["data"]) == 1
        assert body["pagination"]["has_more"] is True
        assert body["pagination"]["next_cursor"] is not None

    def test_pagination_cursor_fetches_next_page(self, dynamodb_table, mock_context):
        """正常系: next_cursor を cursor パラメータに渡すと次ページが返る。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "cursor-user", 4)

        # 1ページ目（limit=2）
        event1 = make_event(
            "GET", "/items", user_id="cursor-user", query_params={"limit": "2"}
        )
        resp1 = handler(event1, mock_context)
        body1 = json.loads(resp1["body"])
        next_cursor = body1["pagination"]["next_cursor"]
        assert next_cursor is not None

        # 2ページ目（cursor 使用）
        event2 = make_event(
            "GET",
            "/items",
            user_id="cursor-user",
            query_params={"limit": "2", "cursor": next_cursor},
        )
        resp2 = handler(event2, mock_context)
        body2 = json.loads(resp2["body"])

        assert resp2["statusCode"] == 200
        assert len(body2["data"]) == 2
        # 1ページ目と重複しない
        ids1 = {item["item_id"] for item in body1["data"]}
        ids2 = {item["item_id"] for item in body2["data"]}
        assert ids1.isdisjoint(ids2)

    def test_pagination_all_items_reachable(self, dynamodb_table, mock_context):
        """正常系: 全ページを走査すると全アイテムを取得できる。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "full-page-user", 5)

        all_ids = set()
        cursor = None

        while True:
            query_params = {"limit": "2"}
            if cursor:
                query_params["cursor"] = cursor
            event = make_event(
                "GET", "/items", user_id="full-page-user", query_params=query_params
            )
            resp = handler(event, mock_context)
            body = json.loads(resp["body"])
            for item in body["data"]:
                all_ids.add(item["item_id"])
            cursor = body["pagination"]["next_cursor"]
            if cursor is None:
                break

        assert len(all_ids) == 5

    def test_invalid_cursor_returns_first_page(self, dynamodb_table, mock_context):
        """
        正常系: 不正な cursor は無視して最初のページを返す。
        クライアントのバグや改ざんに対して 400 を返さない設計（list_items/handler.py 参照）。
        """
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "invalid-cursor-user", 2)

        event = make_event(
            "GET",
            "/items",
            user_id="invalid-cursor-user",
            query_params={"cursor": "!!!invalid-base64!!!"},
        )
        response = handler(event, mock_context)

        # エラーにならず最初のページが返る
        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert len(body["data"]) == 2


class TestListItemsLimitBoundary:
    """limit パラメータの境界値テスト。"""

    def test_limit_1_returns_single_item(self, dynamodb_table, mock_context):
        """境界値: limit=1（最小値）は 1 件だけ返す。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "limit-user", 5)

        event = make_event("GET", "/items", user_id="limit-user", query_params={"limit": "1"})
        response = handler(event, mock_context)

        body = json.loads(response["body"])
        assert len(body["data"]) == 1

    def test_limit_0_clamped_to_1(self, dynamodb_table, mock_context):
        """境界値: limit=0 は min(max(0,1),100)=1 にクランプされる。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "limit-zero-user", 3)

        event = make_event("GET", "/items", user_id="limit-zero-user", query_params={"limit": "0"})
        response = handler(event, mock_context)

        # エラーにならず 1 件が返る
        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert len(body["data"]) == 1

    def test_limit_100_is_max_allowed(self, dynamodb_table, mock_context):
        """境界値: limit=100（最大値）は正常に処理される。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "limit-100-user", 5)

        event = make_event("GET", "/items", user_id="limit-100-user", query_params={"limit": "100"})
        response = handler(event, mock_context)

        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert len(body["data"]) == 5  # 5 件しかないので 5 件返る
        assert body["pagination"]["has_more"] is False

    def test_limit_101_clamped_to_100(self, dynamodb_table, mock_context):
        """
        境界値: limit=101 は 100 にクランプされる（400 エラーにしない設計）。
        handler 内で min(max(...), 100) によりサイレントにクランプされる。
        """
        from list_items.handler import handler

        event = make_event("GET", "/items", query_params={"limit": "101"})
        response = handler(event, mock_context)

        # エラーにならない（400 ではない）
        assert response["statusCode"] == 200

    def test_limit_string_defaults_to_20(self, dynamodb_table, mock_context):
        """境界値: limit が数値に変換できない文字列はデフォルト 20 になる。"""
        from list_items.handler import handler

        _seed_user_items(dynamodb_table, "limit-str-user", 3)

        event = make_event(
            "GET", "/items", user_id="limit-str-user", query_params={"limit": "abc"}
        )
        response = handler(event, mock_context)

        assert response["statusCode"] == 200
