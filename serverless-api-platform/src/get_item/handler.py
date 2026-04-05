# src/get_item/handler.py
#
# GET /items/{id} — 単一アイテムを取得する Lambda 関数。
#
# 処理フロー:
#   1. Cognito JWT の sub クレームから user_id を取得
#   2. パスパラメータから item_id を取得
#   3. DynamoDB GetItem
#   4. 存在しない場合は 404 ItemNotFoundError
#   5. 所有者チェック（自分のアイテムのみ参照可）→ 403 ForbiddenError
#   6. 200 OK でレスポンス

import time

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import APIGatewayRestResolver
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


@app.get("/items/<item_id>")
@tracer.capture_method
def get_item(item_id: str):
    """GET /items/{id} のルートハンドラー。"""
    request_id = app.current_event.raw_event.get("requestContext", {}).get("requestId", "")
    start_ms = time.time() * 1000

    try:
        # Step 1: 認証済みユーザー ID を取得
        user_id = _get_user_id()

        # Step 2-3: DynamoDB GetItem（存在しない場合は ItemNotFoundError）
        item = repo.get(item_id)

        # Step 4: 所有者チェック
        # 他ユーザーのアイテム ID を推測してアクセスする攻撃を防ぐ。
        # 404 ではなく 403 を返すことで「アイテムは存在するが権限がない」を明示する。
        if item.user_id != user_id:
            raise ForbiddenError()

        logger.info("アイテムを取得しました", item_id=item_id)
        metrics.add_metric(name="GetItemSuccess", unit=MetricUnit.Count, value=1)
        metrics.add_metric(
            name="GetItemLatency",
            unit=MetricUnit.Milliseconds,
            value=time.time() * 1000 - start_ms,
        )

        # Step 5: 200 OK でレスポンス
        return res.ok(item.model_dump(), request_id)

    except UnauthorizedError as e:
        logger.warning("認証エラー", error=str(e))
        return res.err("UNAUTHORIZED", str(e), request_id, 401)

    except ItemNotFoundError as e:
        logger.info("アイテムが見つかりません", item_id=item_id)
        return res.err("ITEM_NOT_FOUND", str(e), request_id, 404)

    except ForbiddenError as e:
        # アクセス試行を warning として記録してセキュリティ監査に活用する
        logger.warning("アクセス拒否", item_id=item_id, requesting_user=user_id if "user_id" in dir() else "unknown")
        metrics.add_metric(name="GetItemError", unit=MetricUnit.Count, value=1)
        return res.err("FORBIDDEN", str(e), request_id, 403)

    except Exception:
        logger.exception("get_item で予期しないエラーが発生しました")
        metrics.add_metric(name="GetItemError", unit=MetricUnit.Count, value=1)
        return res.err("INTERNAL_ERROR", "内部エラーが発生しました", request_id, 500)


@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    return app.resolve(event, context)
