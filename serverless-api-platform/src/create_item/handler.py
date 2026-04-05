# src/create_item/handler.py
#
# POST /items — 新しいアイテムを作成する Lambda 関数。
#
# 処理フロー:
#   1. Cognito JWT の sub クレームから user_id を取得
#   2. リクエストボディを ItemCreate でバリデーション
#   3. UUID v4 で item_id を生成
#   4. DynamoDB PutItem（ConditionExpression で重複防止）
#   5. 201 Created でレスポンス

import time
import uuid
from datetime import datetime, timezone, timedelta

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import APIGatewayRestResolver
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.exceptions import ItemAlreadyExistsError, UnauthorizedError
from shared.models import ItemCreate, ItemResponse
from shared.repository import ItemRepository
from shared import response as res

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="ServerlessApiPlatform")

# APIGatewayRestResolver: ルーティング・JSON パース・レスポンス整形を担う。
# enable_validation=False にして手動バリデーションを行う。
# これにより Pydantic エラーを我々のカスタムフォーマットで返せる。
app = APIGatewayRestResolver(enable_validation=False)

repo = ItemRepository()


def _get_user_id() -> str:
    """
    API Gateway の requestContext から認証済みユーザー ID を取得する。
    Cognito オーソライザーが有効な場合は JWT の sub クレームを使用する。
    dev 環境（オーソライザー無効）ではクエリパラメータ ?user_id= でフォールバック。
    """
    # app.current_event.raw_event で生の dict にアクセスする
    raw = app.current_event.raw_event
    claims = raw.get("requestContext", {}).get("authorizer", {}).get("claims", {})
    if sub := claims.get("sub"):
        return sub
    # dev 環境のフォールバック（本番では Cognito オーソライザーを必ず有効化すること）
    if user_id := (app.current_event.query_string_parameters or {}).get("user_id"):
        return user_id
    raise UnauthorizedError()


@app.post("/items")
@tracer.capture_method
def create_item():
    """POST /items のルートハンドラー。"""
    request_id = app.current_event.raw_event.get("requestContext", {}).get("requestId", "")
    start_ms = time.time() * 1000

    try:
        # Step 1: 認証済みユーザー ID を取得
        user_id = _get_user_id()

        # Step 2: リクエストボディを ItemCreate でバリデーション
        body = app.current_event.json_body or {}
        request = ItemCreate(**body)

        # Step 3: UUID v4 で item_id を生成
        now = datetime.now(timezone.utc).isoformat()

        # expires_days が指定されている場合は作成時点で expires_at を設定する。
        # ARCHIVED 変更時の自動 TTL（30日）とは別に、
        # ユーザーが明示的に有効期限を指定できる仕組み。
        expires_at = None
        if request.expires_days is not None:
            expires_at = int(
                (datetime.now(timezone.utc) + timedelta(days=request.expires_days)).timestamp()
            )

        item = ItemResponse(
            item_id=str(uuid.uuid4()),
            user_id=user_id,
            name=request.name,
            description=request.description,
            status="ACTIVE",
            created_at=now,
            updated_at=now,
            expires_at=expires_at,
        )

        # Step 4: DynamoDB PutItem（条件付き書き込み）
        created = repo.create(item)

        logger.info("アイテムを作成しました", item_id=item.item_id, user_id=user_id)
        metrics.add_metric(name="CreateItemSuccess", unit=MetricUnit.Count, value=1)
        metrics.add_metric(
            name="CreateItemLatency",
            unit=MetricUnit.Milliseconds,
            value=time.time() * 1000 - start_ms,
        )

        # Step 5: 201 Created でレスポンス
        return res.ok(created.model_dump(), request_id, status_code=201)

    except UnauthorizedError as e:
        logger.warning("認証エラー", error=str(e))
        return res.err("UNAUTHORIZED", str(e), request_id, 401)

    except (ValueError, KeyError) as e:
        # Pydantic バリデーションエラー（ItemCreate のフィールド制約違反）
        logger.warning("バリデーションエラー", error=str(e))
        metrics.add_metric(name="CreateItemError", unit=MetricUnit.Count, value=1)
        return res.err("VALIDATION_ERROR", str(e), request_id, 400)

    except ItemAlreadyExistsError as e:
        # UUID 衝突は極めてまれ。念のため 409 を返す。
        logger.warning("アイテム重複", item_id=e.item_id)
        return res.err("ITEM_ALREADY_EXISTS", str(e), request_id, 409)

    except Exception:
        logger.exception("create_item で予期しないエラーが発生しました")
        metrics.add_metric(name="CreateItemError", unit=MetricUnit.Count, value=1)
        return res.err("INTERNAL_ERROR", "内部エラーが発生しました", request_id, 500)


@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    return app.resolve(event, context)
