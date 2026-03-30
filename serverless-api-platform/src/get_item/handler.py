# src/get_item/handler.py
#
# GET /items/{id} — 単一アイテムを取得する Lambda 関数。

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import ForbiddenError, ItemNotFoundError
from shared.repository import ItemRepository
from shared.response import error, success

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="ServerlessApiPlatform")

repository = ItemRepository()


@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """
    GET /items/{id} のエントリーポイント。
    認証済みユーザーが所有するアイテムのみ取得可能。
    """
    request_id = event.get("requestContext", {}).get("requestId", "")
    item_id = event.get("pathParameters", {}).get("id", "")

    try:
        user_id = _get_user_id(event)

        item = repository.get(item_id)

        # 所有者チェック: 自分のアイテムのみ参照可能
        if item.user_id != user_id:
            raise ForbiddenError()

        metrics.add_metric(name="GetItemSuccess", unit=MetricUnit.Count, value=1)
        return success(item.model_dump(), request_id)

    except ItemNotFoundError as e:
        logger.info("Item not found", item_id=item_id)
        return error("ITEM_NOT_FOUND", str(e), request_id, 404)

    except ForbiddenError as e:
        logger.warning("Forbidden access", item_id=item_id)
        return error("FORBIDDEN", str(e), request_id, 403)

    except Exception as e:
        logger.exception("Unexpected error in get_item")
        metrics.add_metric(name="GetItemError", unit=MetricUnit.Count, value=1)
        return error("INTERNAL_ERROR", "内部エラーが発生しました", request_id, 500)


def _get_user_id(event: dict) -> str:
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("claims", {})
    )
    if claims.get("sub"):
        return claims["sub"]

    user_id = (event.get("queryStringParameters") or {}).get("user_id")
    if not user_id:
        from shared.exceptions import UnauthorizedError
        raise UnauthorizedError()
    return user_id
