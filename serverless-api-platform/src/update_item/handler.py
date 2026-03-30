# src/update_item/handler.py
#
# PUT /items/{id} — アイテムを更新する Lambda 関数。

import json

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import ForbiddenError, ItemNotFoundError, UnauthorizedError
from shared.models import UpdateItemRequest
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
    PUT /items/{id} のエントリーポイント。
    name, description, status の部分更新に対応する。
    """
    request_id = event.get("requestContext", {}).get("requestId", "")
    item_id = event.get("pathParameters", {}).get("id", "")

    try:
        user_id = _get_user_id(event)

        body = json.loads(event.get("body") or "{}")
        request = UpdateItemRequest(**body)

        updated_item = repository.update(
            item_id=item_id,
            user_id=user_id,
            name=request.name,
            description=request.description,
            status=request.status,
        )

        logger.info("Item updated", item_id=item_id)
        metrics.add_metric(name="UpdateItemSuccess", unit=MetricUnit.Count, value=1)

        return success(updated_item.model_dump(), request_id)

    except ItemNotFoundError as e:
        return error("ITEM_NOT_FOUND", str(e), request_id, 404)

    except ForbiddenError as e:
        return error("FORBIDDEN", str(e), request_id, 403)

    except UnauthorizedError as e:
        return error("UNAUTHORIZED", str(e), request_id, 401)

    except (ValueError, KeyError) as e:
        return error("VALIDATION_ERROR", str(e), request_id, 400)

    except Exception as e:
        logger.exception("Unexpected error in update_item")
        metrics.add_metric(name="UpdateItemError", unit=MetricUnit.Count, value=1)
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
