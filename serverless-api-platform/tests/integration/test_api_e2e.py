# tests/integration/test_api_e2e.py
#
# E2E 統合テスト。実際にデプロイされた API に対してリクエストを送る。
#
# 実行前提:
#   - make apply ENV=dev でデプロイ済みであること
#   - terraform output api_endpoint で URL を取得し、環境変数に設定すること
#
# 実行方法:
#   export API_ENDPOINT=$(cd terraform/environments/dev && terraform output -raw api_endpoint)
#   export TEST_USER_ID=your-test-user-id
#   pytest tests/integration/ -v

import os
import uuid

import pytest
import requests

# 環境変数から API エンドポイントを取得
# 未設定の場合はテストをスキップする
API_ENDPOINT = os.environ.get("API_ENDPOINT")
TEST_USER_ID = os.environ.get("TEST_USER_ID", f"e2e-test-user-{uuid.uuid4()}")


@pytest.mark.skipif(not API_ENDPOINT, reason="API_ENDPOINT 環境変数が未設定")
class TestApiE2E:
    """
    E2E テストクラス。
    テストの実行順序: create → get → list → update → delete
    """

    created_item_id = None

    def test_01_create_item(self):
        """POST /items でアイテムを作成できる。"""
        response = requests.post(
            f"{API_ENDPOINT}/items",
            json={
                "name": "E2E テストアイテム",
                "description": "統合テスト用",
            },
            params={"user_id": TEST_USER_ID},
            timeout=10,
        )

        assert response.status_code == 201
        body = response.json()
        assert body["success"] is True
        assert body["data"]["name"] == "E2E テストアイテム"

        # 後続テストのためにアイテム ID を保存
        TestApiE2E.created_item_id = body["data"]["item_id"]

    def test_02_get_item(self):
        """GET /items/{id} で作成したアイテムを取得できる。"""
        assert TestApiE2E.created_item_id, "test_01 が先に実行されている必要があります"

        response = requests.get(
            f"{API_ENDPOINT}/items/{TestApiE2E.created_item_id}",
            params={"user_id": TEST_USER_ID},
            timeout=10,
        )

        assert response.status_code == 200
        body = response.json()
        assert body["data"]["item_id"] == TestApiE2E.created_item_id

    def test_03_list_items(self):
        """GET /items でアイテム一覧に作成したアイテムが含まれる。"""
        response = requests.get(
            f"{API_ENDPOINT}/items",
            params={"user_id": TEST_USER_ID},
            timeout=10,
        )

        assert response.status_code == 200
        body = response.json()
        assert "pagination" in body
        item_ids = [item["item_id"] for item in body["data"]]
        assert TestApiE2E.created_item_id in item_ids

    def test_04_update_item(self):
        """PUT /items/{id} でアイテムを更新できる。"""
        assert TestApiE2E.created_item_id

        response = requests.put(
            f"{API_ENDPOINT}/items/{TestApiE2E.created_item_id}",
            json={"name": "E2E テストアイテム（更新済み）"},
            params={"user_id": TEST_USER_ID},
            timeout=10,
        )

        assert response.status_code == 200
        body = response.json()
        assert body["data"]["name"] == "E2E テストアイテム（更新済み）"

    def test_05_delete_item(self):
        """DELETE /items/{id} でアイテムを削除できる。"""
        assert TestApiE2E.created_item_id

        response = requests.delete(
            f"{API_ENDPOINT}/items/{TestApiE2E.created_item_id}",
            params={"user_id": TEST_USER_ID},
            timeout=10,
        )

        assert response.status_code == 204

    def test_06_get_deleted_item_returns_404(self):
        """削除済みアイテムへの GET は 404 を返す。"""
        assert TestApiE2E.created_item_id

        response = requests.get(
            f"{API_ENDPOINT}/items/{TestApiE2E.created_item_id}",
            params={"user_id": TEST_USER_ID},
            timeout=10,
        )

        assert response.status_code == 404
        body = response.json()
        assert body["error"]["code"] == "ITEM_NOT_FOUND"
