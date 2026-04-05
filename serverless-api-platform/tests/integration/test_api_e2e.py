# tests/integration/test_api_e2e.py
#
# E2E 統合テスト。実際にデプロイされた dev 環境の API に対してリクエストを送る。
#
# テストシナリオ（CRUD フロー）:
#   1. Cognito でテストユーザー作成・JWT 取得（conftest.py で実施）
#   2. POST   /items         → アイテム作成
#   3. GET    /items/{id}    → 作成アイテムを取得・内容検証
#   4. GET    /items         → 一覧取得・ページネーション確認
#   5. PUT    /items/{id}    → 更新・更新内容確認
#   6. DELETE /items/{id}    → 論理削除
#   7. GET    /items/{id}    → 削除後に status=ARCHIVED であることを確認
#   8. GET    /items/{id}    → 認証なしリクエストで 401 Unauthorized
#   9. Cognito テストユーザー削除（conftest.py で実施）
#
# テスト間の依存関係:
#   テストは実行順に依存する（pytest -p no:randomly で順序を固定）。
#   created_item_id はクラス変数で共有する。

import pytest
import requests

from conftest import API_ENDPOINT, is_integration_env_ready


# 環境変数未設定時にクラス全体をスキップ
pytestmark = pytest.mark.skipif(
    not is_integration_env_ready(),
    reason="Integration テスト環境変数が未設定（API_ENDPOINT / COGNITO_USER_POOL_ID / COGNITO_CLIENT_ID）",
)


class TestApiE2ECRUDFlow:
    """
    API の完全な CRUD フローを E2E で検証するテストクラス。
    実行順序: test_01 → test_02 → ... → test_08
    """

    # テスト間でアイテム ID を共有（クラス変数）
    created_item_id: str | None = None

    # --- 作成 ---

    def test_01_create_item(self, api):
        """
        POST /items: アイテムを作成する。
        作成した item_id を後続テストのために保存する。
        """
        response = api.post(
            "/items",
            json={
                "name": "E2E テストアイテム",
                "description": "統合テスト用アイテム",
                "expires_days": 1,
            },
        )

        assert response.status_code == 201, f"Response: {response.text}"
        body = response.json()
        assert body["success"] is True
        assert body["data"]["name"] == "E2E テストアイテム"
        assert body["data"]["description"] == "統合テスト用アイテム"
        assert body["data"]["status"] == "ACTIVE"
        assert body["data"]["expires_at"] is not None
        assert "item_id" in body["data"]
        assert "meta" in body

        # 後続テストのためにアイテム ID を保存
        TestApiE2ECRUDFlow.created_item_id = body["data"]["item_id"]

    # --- 単体取得 ---

    def test_02_get_item(self, api):
        """
        GET /items/{id}: 作成したアイテムを ID で取得できる。
        全フィールドが正しく返ることを確認する。
        """
        assert TestApiE2ECRUDFlow.created_item_id, "test_01 が先に成功している必要があります"
        item_id = TestApiE2ECRUDFlow.created_item_id

        response = api.get(f"/items/{item_id}")

        assert response.status_code == 200, f"Response: {response.text}"
        body = response.json()
        assert body["success"] is True
        assert body["data"]["item_id"] == item_id
        assert body["data"]["name"] == "E2E テストアイテム"
        assert body["data"]["status"] == "ACTIVE"

    # --- 一覧取得 ---

    def test_03_list_items_contains_created(self, api):
        """
        GET /items: 一覧に作成したアイテムが含まれる。
        ページネーション構造（pagination オブジェクト）も検証する。
        """
        assert TestApiE2ECRUDFlow.created_item_id

        response = api.get("/items", params={"limit": 50})

        assert response.status_code == 200, f"Response: {response.text}"
        body = response.json()
        assert body["success"] is True
        assert "pagination" in body
        assert "has_more" in body["pagination"]
        assert "count" in body["pagination"]
        assert isinstance(body["data"], list)

        item_ids = [item["item_id"] for item in body["data"]]
        assert TestApiE2ECRUDFlow.created_item_id in item_ids

    def test_03b_list_items_pagination(self, api):
        """
        GET /items: limit=1 で複数アイテムがあれば next_cursor が返る。
        cursor を使って次ページが取得できることを確認する。
        """
        # まず 2 件以上作成されているかを確認
        resp = api.get("/items", params={"limit": 100})
        total = resp.json()["pagination"]["count"]

        if total < 2:
            pytest.skip("ページネーションテストには 2 件以上のアイテムが必要")

        # 1 件ずつ取得
        resp1 = api.get("/items", params={"limit": 1})
        body1 = resp1.json()
        assert body1["pagination"]["has_more"] is True
        next_cursor = body1["pagination"]["next_cursor"]
        assert next_cursor is not None

        # cursor で 2 ページ目
        resp2 = api.get("/items", params={"limit": 1, "cursor": next_cursor})
        assert resp2.status_code == 200
        body2 = resp2.json()
        # 1 ページ目と異なるアイテムが返る
        ids1 = {item["item_id"] for item in body1["data"]}
        ids2 = {item["item_id"] for item in body2["data"]}
        assert ids1.isdisjoint(ids2)

    # --- 更新 ---

    def test_04_update_item(self, api):
        """
        PUT /items/{id}: アイテムを更新できる。
        更新後のレスポンスに変更が反映されていることを確認する。
        """
        assert TestApiE2ECRUDFlow.created_item_id
        item_id = TestApiE2ECRUDFlow.created_item_id

        response = api.put(
            f"/items/{item_id}",
            json={
                "name": "E2E テストアイテム（更新済み）",
                "description": "更新後の説明",
            },
        )

        assert response.status_code == 200, f"Response: {response.text}"
        body = response.json()
        assert body["success"] is True
        assert body["data"]["name"] == "E2E テストアイテム（更新済み）"
        assert body["data"]["description"] == "更新後の説明"
        assert body["data"]["item_id"] == item_id

    def test_04b_get_item_reflects_update(self, api):
        """
        更新後に GET /items/{id} を呼ぶと更新内容が反映されている。
        """
        assert TestApiE2ECRUDFlow.created_item_id
        item_id = TestApiE2ECRUDFlow.created_item_id

        response = api.get(f"/items/{item_id}")
        body = response.json()

        assert body["data"]["name"] == "E2E テストアイテム（更新済み）"

    # --- 論理削除 ---

    def test_05_delete_item(self, api):
        """
        DELETE /items/{id}: アイテムを論理削除する。
        204 No Content が返ることを確認する。
        """
        assert TestApiE2ECRUDFlow.created_item_id
        item_id = TestApiE2ECRUDFlow.created_item_id

        response = api.delete(f"/items/{item_id}")

        assert response.status_code == 204, f"Response: {response.text}"

    def test_06_get_deleted_item_is_archived(self, api):
        """
        DELETE 後に GET /items/{id} を呼ぶと status=ARCHIVED のアイテムが返る。

        重要: 論理削除のため物理的には DynamoDB に残っている。
        get_item ハンドラーは status フィルタを行わないため、
        ARCHIVED アイテムも 200 OK で返す（404 ではない）。
        """
        assert TestApiE2ECRUDFlow.created_item_id
        item_id = TestApiE2ECRUDFlow.created_item_id

        response = api.get(f"/items/{item_id}")

        assert response.status_code == 200, f"Response: {response.text}"
        body = response.json()
        assert body["success"] is True
        assert body["data"]["item_id"] == item_id
        assert body["data"]["status"] == "ARCHIVED"
        # expires_at（30日後の TTL）が設定されている
        assert body["data"]["expires_at"] is not None

    # --- 認証エラー ---

    def test_07_no_auth_returns_401(self):
        """
        認証なしリクエスト → 401 Unauthorized。
        API Gateway の Cognito オーソライザーが JWT 検証を行う。
        Lambda まで到達しないため、API Gateway が 401 を直接返す。
        """
        if not API_ENDPOINT:
            pytest.skip("API_ENDPOINT が未設定")

        response = requests.get(
            f"{API_ENDPOINT}/items",
            timeout=15,
        )

        assert response.status_code == 401, (
            f"認証なしリクエストは 401 を期待しましたが {response.status_code} が返りました。"
            "\nCognito オーソライザーが正しく設定されているか確認してください。"
        )

    def test_08_invalid_token_returns_401(self):
        """
        不正な JWT → 401 Unauthorized。
        API Gateway が署名検証で拒否する。
        """
        if not API_ENDPOINT:
            pytest.skip("API_ENDPOINT が未設定")

        response = requests.get(
            f"{API_ENDPOINT}/items",
            headers={"Authorization": "Bearer invalid.jwt.token"},
            timeout=15,
        )

        assert response.status_code == 401


class TestApiE2EValidation:
    """API バリデーションの E2E テスト。"""

    def test_create_missing_name_returns_400(self, api):
        """POST /items: name なしは 400 VALIDATION_ERROR。"""
        response = api.post("/items", json={"description": "名前なし"})

        assert response.status_code == 400
        body = response.json()
        assert body["success"] is False
        assert body["error"]["code"] == "VALIDATION_ERROR"

    def test_update_nonexistent_item_returns_404(self, api):
        """PUT /items/{id}: 存在しない item_id は 404 ITEM_NOT_FOUND。"""
        response = api.put(
            "/items/non-existent-item-id-xyz",
            json={"name": "更新テスト"},
        )

        assert response.status_code == 404
        body = response.json()
        assert body["error"]["code"] == "ITEM_NOT_FOUND"

    def test_update_empty_body_returns_400(self, api):
        """PUT /items/{id}: 更新フィールドなしは 400 VALIDATION_ERROR。"""
        # まずアイテムを作成
        create_resp = api.post("/items", json={"name": "バリデーションテスト用"})
        if create_resp.status_code != 201:
            pytest.skip("アイテム作成に失敗したためスキップ")
        item_id = create_resp.json()["data"]["item_id"]

        response = api.put(f"/items/{item_id}", json={})

        assert response.status_code == 400
        body = response.json()
        assert body["error"]["code"] == "VALIDATION_ERROR"
