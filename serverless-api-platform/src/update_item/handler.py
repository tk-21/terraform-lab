# src/update_item/handler.py
#
# PUT /items/{id} — アイテムを更新する Lambda 関数。
#
# 処理フロー:
#   1. Cognito JWT の sub クレームから user_id を取得
#   2. DynamoDB GetItem で存在確認・所有者確認（先に確認することで明確なエラーを返せる）
#   3. リクエストボディを ItemUpdate でバリデーション
#   4. updated_at を現在時刻で更新
#   5. DynamoDB UpdateItem（ConditionExpression で PK 存在確認）
#   6. 200 OK で更新後アイテムを返却

import time

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import APIGatewayRestResolver
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import ForbiddenError, ItemNotFoundError, UnauthorizedError
from shared.models import ItemUpdate
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


@app.put("/items/<item_id>")
@tracer.capture_method
def update_item(item_id: str):
    """PUT /items/{id} のルートハンドラー。"""
    request_id = app.current_event.raw_event.get("requestContext", {}).get("requestId", "")
    start_ms = time.time() * 1000

    try:
        # Step 1: 認証済みユーザー ID を取得
        user_id = _get_user_id()

        # Step 2: GetItem で存在確認 → 所有者確認
        # UpdateItem の ConditionExpression で所有者チェックを行うと
        # ItemNotFoundError と ForbiddenError を区別できないため、
        # 先に GetItem → アプリ側でチェックする設計とした。
        item = repo.get(item_id)
        if item.user_id != user_id:
            raise ForbiddenError()

        # Step 3: リクエストボディを ItemUpdate でバリデーション
        body = app.current_event.json_body or {}
        request = ItemUpdate(**body)

        # Step 4-5: DynamoDB UpdateItem（updated_at は repository 層で付与）
        updated = repo.update(
            item_id=item_id,
            name=request.name,
            description=request.description,
            status=request.status,
        )

        logger.info("アイテムを更新しました", item_id=item_id, user_id=user_id)
        metrics.add_metric(name="UpdateItemSuccess", unit=MetricUnit.Count, value=1)
        metrics.add_metric(
            name="UpdateItemLatency",
            unit=MetricUnit.Milliseconds,
            value=time.time() * 1000 - start_ms,
        )

        # Step 6: 200 OK で更新後アイテムを返却
        return res.ok(updated.model_dump(), request_id)

    except UnauthorizedError as e:
        logger.warning("認証エラー", error=str(e))
        return res.err("UNAUTHORIZED", str(e), request_id, 401)

    except ItemNotFoundError as e:
        logger.info("アイテムが見つかりません", item_id=item_id)
        return res.err("ITEM_NOT_FOUND", str(e), request_id, 404)

    except ForbiddenError as e:
        logger.warning("アクセス拒否", item_id=item_id)
        metrics.add_metric(name="UpdateItemError", unit=MetricUnit.Count, value=1)
        return res.err("FORBIDDEN", str(e), request_id, 403)

    except (ValueError, KeyError) as e:
        # Pydantic バリデーションエラー（ItemUpdate のフィールド制約違反）
        logger.warning("バリデーションエラー", error=str(e))
        return res.err("VALIDATION_ERROR", str(e), request_id, 400)

    except Exception:
        logger.exception("update_item で予期しないエラーが発生しました")
        metrics.add_metric(name="UpdateItemError", unit=MetricUnit.Count, value=1)
        return res.err("INTERNAL_ERROR", "内部エラーが発生しました", request_id, 500)


@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    return app.resolve(event, context)
