"""
共有ユーティリティ関数
"""
import os
from typing import Any, Callable
from datetime import datetime, timezone, timedelta

from aws_lambda_powertools import Tracer
from decimal import Decimal


def get_env(key: str) -> str:
    """環境変数を取得する。未設定の場合は RuntimeError を送出する。"""
    value = os.environ.get(key)
    if value is None:
        raise RuntimeError(f"環境変数 {key} が設定されていません。")
    return value


def tracing_disabled() -> bool:
    """Powertools Tracer を無効化すべき環境かどうかを返す。"""
    return os.environ.get("POWERTOOLS_TRACE_DISABLED", "").lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


class _NoopTracer:
    """Powertools Tracer の最小 no-op 代替。"""

    def capture_method(self, func: Callable[..., Any] | None = None, **_: Any):
        if func is None:
            return lambda inner: inner
        return func

    def capture_lambda_handler(self, func: Callable[..., Any] | None = None, **_: Any):
        if func is None:
            return lambda inner: inner
        return func


def build_tracer() -> Tracer | _NoopTracer:
    """ローカル/テスト環境では no-op、それ以外では Powertools Tracer を返す。"""
    if tracing_disabled():
        return _NoopTracer()
    return Tracer()


def to_dynamodb_compatible(value: Any) -> Any:
    """boto3 DynamoDB resource が受け付ける型に再帰変換する。"""
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, list):
        return [to_dynamodb_compatible(item) for item in value]
    if isinstance(value, dict):
        return {key: to_dynamodb_compatible(item) for key, item in value.items()}
    return value


def ttl_after_days(days: int = 30) -> int:
    """現在時刻から指定日数後の Unix タイムスタンプ（TTL 用）を返す。"""
    expires = datetime.now(tz=timezone.utc) + timedelta(days=days)
    return int(expires.timestamp())


def make_event_sk(ts: datetime) -> str:
    """DynamoDB SK 用のイベントタイムスタンプ文字列を生成する。"""
    return f"EVENT#{ts.strftime('%Y-%m-%dT%H:%M:%SZ')}"
