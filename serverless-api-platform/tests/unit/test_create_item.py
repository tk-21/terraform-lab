# tests/unit/test_create_item.py
#
# POST /items (create_item Lambda) のユニットテスト。
#
# 検証観点:
#   - バリデーション正常系・異常系（name 欠損・空白・長すぎ）
#   - user_id が JWT の sub クレームから正しく取得される
#   - DynamoDB に正しいスキーマで書き込まれる
#   - 重複アイテムで 409 Conflict が返る
#   - 認証なしリクエストで 401 が返る

import json
import uuid
from unittest.mock import MagicMock, patch

import pytest

# conftest.py で sys.path・os.environ 設定済み
from conftest import make_event


class TestCreateItemValidation:
    """リクエストバリデーションのテスト。"""

    def test_create_success_full_fields(self, dynamodb_table, mock_context):
        """正常系: name・description・expires_days を指定してアイテムが作成される。"""
        from create_item.handler import handler

        event = make_event(
            "POST",
            "/items",
            body={"name": "テストアイテム", "description": "詳細説明", "expires_days": 30},
        )
        response = handler(event, mock_context)

        assert response["statusCode"] == 201
        body = json.loads(response["body"])
        assert body["success"] is True
        assert body["data"]["name"] == "テストアイテム"
        assert body["data"]["description"] == "詳細説明"
        assert body["data"]["status"] == "ACTIVE"
        assert body["data"]["expires_at"] is not None
        assert "item_id" in body["data"]
        assert "created_at" in body["data"]
        assert "updated_at" in body["data"]

    def test_create_success_name_only(self, dynamodb_table, mock_context):
        """正常系: name のみで作成できる（description は任意フィールド）。"""
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "名前のみ"})
        response = handler(event, mock_context)

        assert response["statusCode"] == 201
        body = json.loads(response["body"])
        assert body["data"]["description"] is None
        assert body["data"]["expires_at"] is None

    def test_create_missing_name_returns_400(self, dynamodb_table, mock_context):
        """異常系: name が欠損している場合は 400 VALIDATION_ERROR を返す。"""
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"description": "名前なし"})
        response = handler(event, mock_context)

        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert body["success"] is False
        assert body["error"]["code"] == "VALIDATION_ERROR"

    def test_create_blank_name_returns_400(self, dynamodb_table, mock_context):
        """異常系: 空白のみの name は Pydantic バリデーターで弾かれ 400 を返す。"""
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "   "})
        response = handler(event, mock_context)

        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert body["error"]["code"] == "VALIDATION_ERROR"

    def test_create_name_too_long_returns_400(self, dynamodb_table, mock_context):
        """異常系: name が 101 文字以上は 400 を返す（最大 100 文字）。"""
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "あ" * 101})
        response = handler(event, mock_context)

        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert body["error"]["code"] == "VALIDATION_ERROR"

    def test_create_description_too_long_returns_400(self, dynamodb_table, mock_context):
        """異常系: description が 1001 文字以上は 400 を返す（最大 1000 文字）。"""
        from create_item.handler import handler

        event = make_event(
            "POST", "/items", body={"name": "正常な名前", "description": "あ" * 1001}
        )
        response = handler(event, mock_context)

        assert response["statusCode"] == 400

    def test_create_name_at_max_length_succeeds(self, dynamodb_table, mock_context):
        """境界値: name が 100 文字は正常に作成できる（上限境界）。"""
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "あ" * 100})
        response = handler(event, mock_context)

        assert response["statusCode"] == 201

    def test_create_expires_days_out_of_range_returns_400(self, dynamodb_table, mock_context):
        """異常系: expires_days が 366 以上は 400 を返す（最大 365）。"""
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "期限テスト", "expires_days": 366})
        response = handler(event, mock_context)

        assert response["statusCode"] == 400


class TestCreateItemAuth:
    """認証・user_id 取得のテスト。"""

    def test_user_id_from_cognito_jwt_sub(self, dynamodb_table, mock_context):
        """
        正常系: Cognito JWT の sub クレームから user_id が取得される。
        API Gateway オーソライザーが設定した requestContext.authorizer.claims.sub を使用。
        """
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "JWT テスト"}, user_id="cognito-sub-abc")
        response = handler(event, mock_context)

        assert response["statusCode"] == 201
        body = json.loads(response["body"])
        assert body["data"]["user_id"] == "cognito-sub-abc"

    def test_user_id_from_query_param_fallback(self, dynamodb_table, mock_context):
        """
        正常系（dev 環境フォールバック）: Cognito がない場合は ?user_id= から取得する。
        本番では Cognito オーソライザーを必ず有効化すること（CLAUDE.md 禁止事項）。
        """
        from create_item.handler import handler

        event = make_event(
            "POST",
            "/items",
            body={"name": "フォールバックテスト"},
            include_auth=False,
        )
        event["queryStringParameters"] = {"user_id": "fallback-user-001"}
        response = handler(event, mock_context)

        assert response["statusCode"] == 201
        body = json.loads(response["body"])
        assert body["data"]["user_id"] == "fallback-user-001"

    def test_no_auth_returns_401(self, dynamodb_table, mock_context):
        """異常系: 認証情報が一切ない場合は 401 UNAUTHORIZED を返す。"""
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "認証なし"}, include_auth=False)
        # query_params も設定しない → UnauthorizedError
        response = handler(event, mock_context)

        assert response["statusCode"] == 401
        body = json.loads(response["body"])
        assert body["success"] is False
        assert body["error"]["code"] == "UNAUTHORIZED"


class TestCreateItemDynamoDBSchema:
    """DynamoDB への書き込みスキーマのテスト。"""

    def test_dynamodb_single_table_schema(self, dynamodb_table, mock_context):
        """
        正常系: Single Table Design に従ったキー形式（ITEM#<uuid>）で書き込まれる。
        PK/SK が ITEM#<item_id> 形式であることを DynamoDB から直接検証する。
        """
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "スキーマ確認"})
        response = handler(event, mock_context)

        item_id = json.loads(response["body"])["data"]["item_id"]

        raw = dynamodb_table.get_item(
            Key={"PK": f"ITEM#{item_id}", "SK": f"ITEM#{item_id}"}
        )["Item"]

        assert raw["PK"] == f"ITEM#{item_id}"
        assert raw["SK"] == f"ITEM#{item_id}"
        assert raw["item_id"] == item_id
        assert raw["status"] == "ACTIVE"
        assert "created_at" in raw
        assert "updated_at" in raw
        assert raw["created_at"] == raw["updated_at"]  # 作成時は同一

    def test_dynamodb_user_id_stored_correctly(self, dynamodb_table, mock_context):
        """
        正常系: GSI-1（user-index）のパーティションキーとなる user_id が正しく保存される。
        list_by_user の Query が機能するために重要。
        """
        from create_item.handler import handler

        event = make_event("POST", "/items", body={"name": "user_id 確認"}, user_id="gsi-test-user")
        response = handler(event, mock_context)
        item_id = json.loads(response["body"])["data"]["item_id"]

        raw = dynamodb_table.get_item(
            Key={"PK": f"ITEM#{item_id}", "SK": f"ITEM#{item_id}"}
        )["Item"]
        assert raw["user_id"] == "gsi-test-user"


class TestCreateItemDuplicate:
    """重複アイテム（409 Conflict）のテスト。"""

    def test_duplicate_uuid_returns_409(self, dynamodb_table, mock_context):
        """
        異常系: 同一 UUID のアイテムを2回作成しようとすると 409 ITEM_ALREADY_EXISTS。
        uuid.uuid4 をモックして同一 ID を強制的に生成させる。
        """
        from create_item.handler import handler

        fixed_uuid = uuid.UUID("aaaabbbb-aaaa-bbbb-cccc-ddddeeeeffffg"[:36])
        fixed_uuid = uuid.UUID("aaaabbbb-aaaa-bbbb-cccc-ddddeeee0001")

        # 1回目: 正常作成
        with patch("create_item.handler.uuid.uuid4", return_value=fixed_uuid):
            event1 = make_event("POST", "/items", body={"name": "初回作成"})
            response1 = handler(event1, mock_context)
        assert response1["statusCode"] == 201

        # 2回目: 同一 UUID → 409
        with patch("create_item.handler.uuid.uuid4", return_value=fixed_uuid):
            event2 = make_event("POST", "/items", body={"name": "重複作成"})
            response2 = handler(event2, mock_context)

        assert response2["statusCode"] == 409
        body = json.loads(response2["body"])
        assert body["success"] is False
        assert body["error"]["code"] == "ITEM_ALREADY_EXISTS"
