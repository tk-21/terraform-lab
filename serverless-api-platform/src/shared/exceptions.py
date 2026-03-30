# src/shared/exceptions.py
#
# API 全体で使用するカスタム例外クラス。
# 各例外は HTTP ステータスコードにマッピングされる。
# Lambda の共通エラーハンドラーがこれらを catch して適切なレスポンスを返す。


class ItemNotFoundError(Exception):
    """
    指定されたアイテムが DynamoDB に存在しない場合に発生。
    → HTTP 404 Not Found にマッピングされる。
    """

    def __init__(self, item_id: str):
        self.item_id = item_id
        super().__init__(f"アイテムが見つかりません: {item_id}")


class ItemAlreadyExistsError(Exception):
    """
    同一 ID のアイテムを作成しようとした場合に発生。
    → HTTP 409 Conflict にマッピングされる。
    """

    def __init__(self, item_id: str):
        self.item_id = item_id
        super().__init__(f"アイテムは既に存在します: {item_id}")


class ValidationError(Exception):
    """
    リクエストボディのバリデーションエラー。
    Pydantic によるバリデーションエラーをラップする。
    → HTTP 400 Bad Request にマッピングされる。
    """

    def __init__(self, message: str, field: str | None = None):
        self.field = field
        super().__init__(message)


class UnauthorizedError(Exception):
    """
    認証情報が無効または不足している場合に発生。
    → HTTP 401 Unauthorized にマッピングされる。
    注意: Cognito オーソライザーが設定されている場合、
    API Gateway がトークン検証を行うため、
    Lambda 側でこのエラーを発生させる機会は限定的。
    """

    def __init__(self, message: str = "認証が必要です"):
        super().__init__(message)


class ForbiddenError(Exception):
    """
    認証済みだが、対象リソースへのアクセス権限がない場合に発生。
    例: 他ユーザーのアイテムを更新・削除しようとした場合。
    → HTTP 403 Forbidden にマッピングされる。
    """

    def __init__(self, message: str = "このリソースへのアクセス権限がありません"):
        super().__init__(message)
