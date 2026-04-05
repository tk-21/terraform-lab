# src/list_items/handler.py
#
# GET /items — ユーザーのアイテム一覧を取得する Lambda 関数。
#
# 処理フロー:
#   1. Cognito JWT の sub クレームから user_id を取得
#   2. クエリパラメータから limit（デフォルト20, 最大100）・cursor を取得
#   3. DynamoDB Query（GSI-1: user-index）でページネーション付き取得
#   4. DynamoDB の LastEvaluatedKey を Base64 エンコードして next_cursor に変換
#   5. paginated レスポンスで返却
#
# ページネーション設計:
#   cursor = Base64(JSON(DynamoDB ExclusiveStartKey))
#   クライアントは next_cursor が null になるまでリクエストを繰り返す。

import base64
import json
import time

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import APIGatewayRestResolver
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import UnauthorizedError
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


@app.get("/items")
@tracer.capture_method
def list_items():
    """GET /items のルートハンドラー。"""
    request_id = app.current_event.raw_event.get("requestContext", {}).get("requestId", "")
    start_ms = time.time() * 1000

    try:
        # Step 1: 認証済みユーザー ID を取得
        user_id = _get_user_id()

        # Step 2: クエリパラメータを取得
        query_params = app.current_event.query_string_parameters or {}

        # limit は 1〜100 の範囲に制限する（無制限クエリによるコスト爆発を防ぐ）
        try:
            limit = min(max(int(query_params.get("limit", 20)), 1), 100)
        except (ValueError, TypeError):
            limit = 20

        cursor = query_params.get("cursor")

        # Step 3: cursor を DynamoDB の ExclusiveStartKey にデコード
        # cursor = Base64(JSON(ExclusiveStartKey)) 形式
        last_evaluated_key = None
        if cursor:
            try:
                last_evaluated_key = json.loads(base64.b64decode(cursor).decode())
            except Exception:
                # 不正な cursor は無視して最初のページから返す
                logger.warning("不正な cursor を無視します", cursor=cursor)

        # Step 4: DynamoDB クエリ（Scan 禁止 → GSI-1 で Query）
        items, next_key = repo.list_by_user(
            user_id=user_id,
            limit=limit,
            last_evaluated_key=last_evaluated_key,
        )

        # Step 5: LastEvaluatedKey を Base64 エンコードして next_cursor に変換
        # クライアントに DynamoDB 内部キー構造を隠蔽するため Base64 でラップする
        next_cursor = None
        if next_key:
            next_cursor = base64.b64encode(json.dumps(next_key).encode()).decode()

        logger.info(
            "アイテム一覧を取得しました",
            user_id=user_id,
            count=len(items),
            has_more=next_cursor is not None,
        )
        metrics.add_metric(name="ListItemsSuccess", unit=MetricUnit.Count, value=1)
        metrics.add_metric(
            name="ListItemsLatency",
            unit=MetricUnit.Milliseconds,
            value=time.time() * 1000 - start_ms,
        )

        return res.paged(
            data=[item.model_dump() for item in items],
            request_id=request_id,
            next_cursor=next_cursor,
            count=len(items),
        )

    except UnauthorizedError as e:
        logger.warning("認証エラー", error=str(e))
        return res.err("UNAUTHORIZED", str(e), request_id, 401)

    except Exception:
        logger.exception("list_items で予期しないエラーが発生しました")
        metrics.add_metric(name="ListItemsError", unit=MetricUnit.Count, value=1)
        return res.err("INTERNAL_ERROR", "内部エラーが発生しました", request_id, 500)


@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    return app.resolve(event, context)
