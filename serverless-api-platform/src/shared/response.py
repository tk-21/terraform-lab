# src/shared/response.py
#
# API レスポンスの共通フォーマット生成ユーティリティ。
# CLAUDE.md で定義されたレスポンス形式に統一する。
#
# 成功:     {"success": true, "data": {...}, "meta": {...}}
# エラー:   {"success": false, "error": {"code": "...", "message": "...", "request_id": "..."}}
# 一覧:     {"success": true, "data": [...], "pagination": {...}, "meta": {...}}
#
# APIGatewayRestResolver ルート関数からは ok() / err() / paged() を使用すること。
# これらは Powertools Response オブジェクトを返すため、app.resolve() と組み合わせて動作する。

import json
from datetime import datetime, timezone
from typing import Any, Optional

from aws_lambda_powertools.event_handler import Response

# CORS ヘッダー（本番では Allow-Origin を特定ドメインに制限すること）
_CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
}


def ok(data: Any, request_id: str, status_code: int = 200) -> Response:
    """
    成功レスポンスを Powertools Response オブジェクトで返す。
    APIGatewayRestResolver ルート関数からこの関数を使用する。

    Args:
        data: レスポンスデータ（dict または list）
        request_id: API Gateway リクエスト ID
        status_code: HTTP ステータスコード（デフォルト 200）
    """
    body = json.dumps(
        {
            "success": True,
            "data": data,
            "meta": {
                "request_id": request_id,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            },
        },
        ensure_ascii=False,
        default=str,  # datetime や Decimal など JSON 非対応型を文字列に変換
    )
    return Response(
        status_code=status_code,
        content_type="application/json",
        body=body,
        headers=_CORS_HEADERS,
    )


def err(code: str, message: str, request_id: str, status_code: int = 500) -> Response:
    """
    エラーレスポンスを Powertools Response オブジェクトで返す。

    Args:
        code: エラーコード（例: "ITEM_NOT_FOUND", "VALIDATION_ERROR"）
        message: ユーザー向けエラーメッセージ
        request_id: API Gateway リクエスト ID
        status_code: HTTP ステータスコード
    """
    body = json.dumps(
        {
            "success": False,
            "error": {
                "code": code,
                "message": message,
                "request_id": request_id,
            },
        },
        ensure_ascii=False,
    )
    return Response(
        status_code=status_code,
        content_type="application/json",
        body=body,
        headers=_CORS_HEADERS,
    )


def paged(
    data: list,
    request_id: str,
    next_cursor: Optional[str] = None,
    count: Optional[int] = None,
) -> Response:
    """
    ページネーション付き一覧レスポンスを Powertools Response オブジェクトで返す。

    Args:
        data: アイテムのリスト
        request_id: API Gateway リクエスト ID
        next_cursor: 次ページカーソル（DynamoDB ExclusiveStartKey を Base64 エンコードした値）
        count: 返却件数（省略時は len(data)）
    """
    body = json.dumps(
        {
            "success": True,
            "data": data,
            "pagination": {
                "next_cursor": next_cursor,
                "has_more": next_cursor is not None,
                "count": count if count is not None else len(data),
            },
            "meta": {
                "request_id": request_id,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            },
        },
        ensure_ascii=False,
        default=str,
    )
    return Response(
        status_code=200,
        content_type="application/json",
        body=body,
        headers=_CORS_HEADERS,
    )
