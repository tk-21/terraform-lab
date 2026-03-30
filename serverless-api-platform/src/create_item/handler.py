# src/create_item/handler.py
#
# POST /items — 新しいアイテムを作成する Lambda 関数。

import json
import uuid
from datetime import datetime, timezone

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import UnauthorizedError, ValidationError
from shared.models import CreateItemRequest, Item, ItemStatus
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
    POST /items のエントリーポイント。

    リクエストボディ:
        name: アイテム名（必須）
        description: 説明（オプション）
    """
    request_id = event.get("requestContext", {}).get("requestId", "")

    try:
        user_id = _get_user_id(event)

        # リクエストボディのパースとバリデーション
        body = json.loads(event.get("body") or "{}")
        request = CreateItemRequest(**body)

        # アイテムモデルを生成
        now = datetime.now(timezone.utc).isoformat()
        item = Item(
            item_id=str(uuid.uuid4()),
            user_id=user_id,
            name=request.name,
            description=request.description,
            status=ItemStatus.ACTIVE,
            created_at=now,
            updated_at=now,
        )

        created_item = repository.create(item)

        logger.info("Item created", item_id=item.item_id)
        metrics.add_metric(name="CreateItemSuccess", unit=MetricUnit.Count, value=1)

        # 201 Created を返す
        return success(created_item.model_dump(), request_id, status_code=201)

    except (ValueError, KeyError) as e:
        # Pydantic バリデーションエラー
        logger.warning("Validation error", error=str(e))
        return error("VALIDATION_ERROR", str(e), request_id, 400)

    except UnauthorizedError as e:
        return error("UNAUTHORIZED", str(e), request_id, 401)

    except Exception as e:
        logger.exception("Unexpected error in create_item")
        metrics.add_metric(name="CreateItemError", unit=MetricUnit.Count, value=1)
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
