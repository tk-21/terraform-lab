# src/shared/response.py
#
# API レスポンスの共通フォーマット生成ユーティリティ。
# CLAUDE.md で定義されたレスポンス形式に統一する。
#
# 成功: {"success": true, "data": {...}, "meta": {...}}
# エラー: {"success": false, "error": {"code": "...", "message": "...", "request_id": "..."}}
# ページネーション: {"success": true, "data": [...], "pagination": {...}}

import json
from datetime import datetime, timezone
from typing import Any

from aws_lambda_powertools import Logger

logger = Logger()


def success(data: Any, request_id: str, status_code: int = 200) -> dict:
    """
    成功レスポンスを生成する。

    Args:
        data: レスポンスボディのデータ。dict または list を受け取る。
        request_id: API Gateway のリクエスト ID。トレーサビリティのため含める。
        status_code: HTTP ステータスコード。デフォルト 200。
    """
    return {
        "statusCode": status_code,
        "headers": _cors_headers(),
        "body": json.dumps(
            {
                "success": True,
                "data": data,
                "meta": {
                    "request_id": request_id,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                },
            },
            ensure_ascii=False,
            default=str,  # datetime など JSON 非対応型を文字列に変換
        ),
    }


def paginated(
    data: list,
    request_id: str,
    next_cursor: str | None = None,
    count: int | None = None,
) -> dict:
    """
    ページネーション付きレスポンスを生成する。

    Args:
        data: アイテムのリスト。
        request_id: リクエスト ID。
        next_cursor: 次ページの DynamoDB ExclusiveStartKey を Base64 エンコードした値。
                     None の場合は最終ページ。
        count: 返却したアイテム数。
    """
    return {
        "statusCode": 200,
        "headers": _cors_headers(),
        "body": json.dumps(
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
        ),
    }


def error(
    code: str,
    message: str,
    request_id: str,
    status_code: int = 500,
) -> dict:
    """
    エラーレスポンスを生成する。

    Args:
        code: エラーコード。例: "ITEM_NOT_FOUND", "VALIDATION_ERROR"
        message: ユーザー向けエラーメッセージ。
        request_id: リクエスト ID。
        status_code: HTTP ステータスコード。
    """
    return {
        "statusCode": status_code,
        "headers": _cors_headers(),
        "body": json.dumps(
            {
                "success": False,
                "error": {
                    "code": code,
                    "message": message,
                    "request_id": request_id,
                },
            },
            ensure_ascii=False,
        ),
    }


def _cors_headers() -> dict:
    """
    CORS ヘッダーを返す。
    本番環境では Allow-Origin を特定のドメインに制限すること。
    """
    return {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type,Authorization",
        "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
    }
