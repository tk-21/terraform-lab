# tests/integration/conftest.py
#
# Integration テスト（E2E）の共通 fixtures。
# 実際にデプロイされた dev 環境の AWS リソースを使用する。
#
# 前提条件:
#   - make apply ENV=dev でデプロイ済みであること
#   - 以下の環境変数が設定されていること:
#       API_ENDPOINT          : API Gateway の URL（terraform output api_endpoint）
#       COGNITO_USER_POOL_ID  : Cognito User Pool ID（terraform output cognito_user_pool_id）
#       COGNITO_CLIENT_ID     : Cognito App Client ID（terraform output cognito_client_id）
#
# 実行方法:
#   export API_ENDPOINT=$(cd terraform/environments/dev && terraform output -raw api_endpoint)
#   export COGNITO_USER_POOL_ID=$(cd terraform/environments/dev && terraform output -raw cognito_user_pool_id)
#   export COGNITO_CLIENT_ID=$(cd terraform/environments/dev && terraform output -raw cognito_client_id)
#   make test-integration

import os
import uuid

import boto3
import pytest
import requests


# --- 環境変数チェック ---

API_ENDPOINT = os.environ.get("API_ENDPOINT", "").rstrip("/")
COGNITO_USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
COGNITO_CLIENT_ID = os.environ.get("COGNITO_CLIENT_ID", "")
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1")

_REQUIRED_ENVS = {
    "API_ENDPOINT": API_ENDPOINT,
    "COGNITO_USER_POOL_ID": COGNITO_USER_POOL_ID,
    "COGNITO_CLIENT_ID": COGNITO_CLIENT_ID,
}
_MISSING = [k for k, v in _REQUIRED_ENVS.items() if not v]

# 必須環境変数が未設定の場合、モジュールロード時に警告（テストは skipif でスキップ）
if _MISSING:
    import warnings
    warnings.warn(
        f"Integration テストに必要な環境変数が未設定です: {', '.join(_MISSING)}\n"
        "  make test-integration 実行前に設定してください。",
        stacklevel=1,
    )


def is_integration_env_ready() -> bool:
    """Integration テスト実行に必要な環境変数がすべて設定されているか確認する。"""
    return all(_REQUIRED_ENVS.values())


# --- テストユーザー管理 ---

TEST_USER_PASSWORD = "Test@Password123!"  # Cognito デフォルトポリシーを満たすパスワード


def _cognito_client():
    return boto3.client("cognito-idp", region_name=AWS_REGION)


def create_test_user(username: str) -> None:
    """
    Cognito User Pool にテストユーザーを作成し、パスワードを確定させる。
    AdminCreateUser → AdminSetUserPassword（PERMANENT）の順で実行する。
    """
    client = _cognito_client()
    client.admin_create_user(
        UserPoolId=COGNITO_USER_POOL_ID,
        Username=username,
        TemporaryPassword=TEST_USER_PASSWORD,
        MessageAction="SUPPRESS",  # 招待メール不送信
    )
    # FORCE_CHANGE_PASSWORD をスキップして CONFIRMED 状態にする
    client.admin_set_user_password(
        UserPoolId=COGNITO_USER_POOL_ID,
        Username=username,
        Password=TEST_USER_PASSWORD,
        Permanent=True,
    )


def delete_test_user(username: str) -> None:
    """Cognito User Pool からテストユーザーを削除する（クリーンアップ用）。"""
    try:
        _cognito_client().admin_delete_user(
            UserPoolId=COGNITO_USER_POOL_ID,
            Username=username,
        )
    except Exception:
        # クリーンアップ失敗は警告のみ（テスト結果に影響させない）
        pass


def get_id_token(username: str) -> str:
    """
    Cognito の USER_PASSWORD_AUTH フローで認証し、ID トークンを取得する。
    API Gateway の Cognito オーソライザーは Authorization ヘッダーの ID トークンを検証する。
    """
    client = _cognito_client()
    response = client.initiate_auth(
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={
            "USERNAME": username,
            "PASSWORD": TEST_USER_PASSWORD,
        },
        ClientId=COGNITO_CLIENT_ID,
    )
    return response["AuthenticationResult"]["IdToken"]


# --- Fixtures ---


@pytest.fixture(scope="session")
def test_username() -> str:
    """セッション全体で共有するテストユーザー名（UUID サフィックスで一意にする）。"""
    return f"e2e-test-{uuid.uuid4().hex[:8]}@example.com"


@pytest.fixture(scope="session")
def cognito_user(test_username):
    """
    テストユーザーを作成し、セッション終了後に削除する。
    scope=session: 全テストで同一ユーザーを共有し、Cognito API 呼び出しを最小化する。
    """
    if not is_integration_env_ready():
        pytest.skip("Integration テスト環境変数が未設定")

    create_test_user(test_username)
    yield test_username
    delete_test_user(test_username)


@pytest.fixture(scope="session")
def auth_headers(cognito_user):
    """
    認証済みリクエストヘッダー。
    Cognito ID トークンを Bearer トークンとして Authorization ヘッダーに設定する。
    """
    token = get_id_token(cognito_user)
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }


@pytest.fixture(scope="session")
def api(auth_headers):
    """
    API クライアントファクトリ。
    認証ヘッダーを自動付与して HTTP リクエストを送る。
    """

    class ApiClient:
        def __init__(self, base_url: str, headers: dict):
            self.base = base_url
            self.headers = headers

        def get(self, path: str, **kwargs) -> requests.Response:
            return requests.get(f"{self.base}{path}", headers=self.headers, timeout=15, **kwargs)

        def post(self, path: str, json: dict = None, **kwargs) -> requests.Response:
            return requests.post(
                f"{self.base}{path}", json=json, headers=self.headers, timeout=15, **kwargs
            )

        def put(self, path: str, json: dict = None, **kwargs) -> requests.Response:
            return requests.put(
                f"{self.base}{path}", json=json, headers=self.headers, timeout=15, **kwargs
            )

        def delete(self, path: str, **kwargs) -> requests.Response:
            return requests.delete(
                f"{self.base}{path}", headers=self.headers, timeout=15, **kwargs
            )

    return ApiClient(API_ENDPOINT, auth_headers)
