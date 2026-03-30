# src/delete_item/handler.py
#
# DELETE /items/{id} — アイテムを削除する Lambda 関数。

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import ForbiddenError, ItemNotFoundError, UnauthorizedError
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
    DELETE /items/{id} のエントリーポイント。
    削除成功時は 204 No Content を返す。
    """
    request_id = event.get("requestContext", {}).get("requestId", "")
    item_id = event.get("pathParameters", {}).get("id", "")

    try:
        user_id = _get_user_id(event)

        repository.delete(item_id=item_id, user_id=user_id)

        logger.info("Item deleted", item_id=item_id)
        metrics.add_metric(name="DeleteItemSuccess", unit=MetricUnit.Count, value=1)

        # 削除成功は 204 No Content（ボディなし）
        return success(None, request_id, status_code=204)

    except ItemNotFoundError as e:
        return error("ITEM_NOT_FOUND", str(e), request_id, 404)

    except ForbiddenError as e:
        return error("FORBIDDEN", str(e), request_id, 403)

    except UnauthorizedError as e:
        return error("UNAUTHORIZED", str(e), request_id, 401)

    except Exception as e:
        logger.exception("Unexpected error in delete_item")
        metrics.add_metric(name="DeleteItemError", unit=MetricUnit.Count, value=1)
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
        raise UnauthorizedError()
    return user_id
