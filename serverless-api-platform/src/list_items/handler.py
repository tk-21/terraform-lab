# src/list_items/handler.py
#
# GET /items — ユーザーのアイテム一覧を取得する Lambda 関数。
#
# DynamoDB の GSI-1 (user-index) を使用して、
# 認証済みユーザーのアイテムを created_at 降順で返す。
# ページネーションは DynamoDB の ExclusiveStartKey を Base64 エンコードした
# cursor パラメータで実装する。

import base64
import json
import os

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import UnauthorizedError
from shared.repository import ItemRepository
from shared.response import error, paginated

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="ServerlessApiPlatform")

repository = ItemRepository()


@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """
    GET /items のエントリーポイント。

    クエリパラメータ:
        limit: 取得件数（デフォルト 20、最大 100）
        cursor: ページネーションカーソル（前のレスポンスの next_cursor）
    """
    request_id = event.get("requestContext", {}).get("requestId", "")

    try:
        # Cognito オーソライザーが設定されている場合、
        # requestContext.authorizer.claims.sub からユーザー ID を取得できる。
        # dev 環境（認証なし）では queryStringParameters からフォールバック。
        user_id = _get_user_id(event)

        # クエリパラメータの取得
        query_params = event.get("queryStringParameters") or {}
        limit = min(int(query_params.get("limit", 20)), 100)  # 最大100件
        cursor = query_params.get("cursor")

        # cursor を DynamoDB の ExclusiveStartKey にデコード
        last_evaluated_key = None
        if cursor:
            last_evaluated_key = json.loads(base64.b64decode(cursor).decode())

        # DynamoDB クエリ（Scan は使用しない）
        items, next_key = repository.list_by_user(
            user_id=user_id,
            limit=limit,
            last_evaluated_key=last_evaluated_key,
        )

        # 次ページのカーソルを Base64 エンコード
        next_cursor = None
        if next_key:
            next_cursor = base64.b64encode(json.dumps(next_key).encode()).decode()

        metrics.add_metric(name="ListItemsSuccess", unit=MetricUnit.Count, value=1)

        return paginated(
            data=[item.model_dump() for item in items],
            request_id=request_id,
            next_cursor=next_cursor,
            count=len(items),
        )

    except UnauthorizedError as e:
        logger.warning("Unauthorized access", exc_info=e)
        return error("UNAUTHORIZED", str(e), request_id, 401)

    except Exception as e:
        logger.exception("Unexpected error in list_items")
        metrics.add_metric(name="ListItemsError", unit=MetricUnit.Count, value=1)
        return error("INTERNAL_ERROR", "内部エラーが発生しました", request_id, 500)


def _get_user_id(event: dict) -> str:
    """
    API Gateway イベントから認証済みユーザー ID を取得する。
    Cognito 認証時は JWT の sub クレームを使用する。
    """
    # Cognito オーソライザーが有効な場合
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("claims", {})
    )
    if claims.get("sub"):
        return claims["sub"]

    # dev 環境のフォールバック（クエリパラメータから取得）
    # 本番環境では Cognito オーソライザーを必ず有効化すること
    user_id = (event.get("queryStringParameters") or {}).get("user_id")
    if not user_id:
        raise UnauthorizedError("user_id が指定されていません（dev 環境では ?user_id=xxx を指定）")
    return user_id
