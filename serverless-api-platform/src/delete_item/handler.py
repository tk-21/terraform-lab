# src/delete_item/handler.py
#
# DELETE /items/{id} — アイテムを削除する Lambda 関数。
#
# 処理フロー:
#   1. Cognito JWT の sub クレームから user_id を取得
#   2. DynamoDB GetItem で存在確認・所有者確認
#   3. 論理削除（status = ARCHIVED、expires_at = 30日後）
#   4. 204 No Content
#
# 物理削除ではなく論理削除を採用した理由は repository.py のコメント参照。

import time

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import APIGatewayRestResolver, Response
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import ForbiddenError, ItemNotFoundError, UnauthorizedError
from shared.repository import ItemRepository
from shared import response as res

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="ServerlessApiPlatform")

app = APIGatewayRestResolver(enable_validation=False)

repo = ItemRepository()


def _get_user_id() -> str:
    """
    Cognito JWT の sub クレームからユーザー ID を取得する。
    dev 環境ではクエリパラメータ ?user_id= でフォールバック。
    """
    raw = app.current_event.raw_event
    claims = raw.get("requestContext", {}).get("authorizer", {}).get("claims", {})
    if sub := claims.get("sub"):
        return sub
    if user_id := (app.current_event.query_string_parameters or {}).get("user_id"):
        return user_id
    raise UnauthorizedError()


@app.delete("/items/<item_id>")
@tracer.capture_method
def delete_item(item_id: str):
    """DELETE /items/{id} のルートハンドラー。"""
    request_id = app.current_event.raw_event.get("requestContext", {}).get("requestId", "")
    start_ms = time.time() * 1000

    try:
        # Step 1: 認証済みユーザー ID を取得
        user_id = _get_user_id()

        # Step 2: GetItem で存在確認 → 所有者確認
        # update_item と同様に、先に GetItem → アプリ側でチェックする。
        item = repo.get(item_id)
        if item.user_id != user_id:
            raise ForbiddenError()

        # Step 3: 論理削除（status = ARCHIVED, expires_at = 30日後）
        repo.delete(item_id)

        logger.info("アイテムを削除しました（論理削除）", item_id=item_id, user_id=user_id)
        metrics.add_metric(name="DeleteItemSuccess", unit=MetricUnit.Count, value=1)
        metrics.add_metric(
            name="DeleteItemLatency",
            unit=MetricUnit.Milliseconds,
            value=time.time() * 1000 - start_ms,
        )

        # Step 4: 204 No Content（削除成功はボディなし）
        return Response(status_code=204, content_type="application/json", body="")

    except UnauthorizedError as e:
        logger.warning("認証エラー", error=str(e))
        return res.err("UNAUTHORIZED", str(e), request_id, 401)

    except ItemNotFoundError as e:
        logger.info("アイテムが見つかりません", item_id=item_id)
        return res.err("ITEM_NOT_FOUND", str(e), request_id, 404)

    except ForbiddenError as e:
        logger.warning("アクセス拒否", item_id=item_id)
        metrics.add_metric(name="DeleteItemError", unit=MetricUnit.Count, value=1)
        return res.err("FORBIDDEN", str(e), request_id, 403)

    except Exception:
        logger.exception("delete_item で予期しないエラーが発生しました")
        metrics.add_metric(name="DeleteItemError", unit=MetricUnit.Count, value=1)
        return res.err("INTERNAL_ERROR", "内部エラーが発生しました", request_id, 500)


@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    return app.resolve(event, context)
