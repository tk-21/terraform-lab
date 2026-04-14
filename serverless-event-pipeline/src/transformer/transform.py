"""
transformer ビジネスロジック変換処理

Kinesis レコードを DynamoDB アイテム形式に変換する純粋関数群。
副作用（I/O・外部依存）を持たないため、boto3 モックなしで単体テストできる。

変換フロー:
  raw dict (Kinesis JSON)
    → バリデーション（必須フィールド・型チェック）
    → entity_id 正規化（大文字化）
    → イベントタイプ別ビジネスロジック変換（PURCHASE / VIEW / CLICK）
    → DynamoDB アイテム形式に組み立て（PK/SK/TTL/status）
"""

from datetime import datetime, timezone, timedelta
from typing import Any


# DynamoDB TTL: レコードを自動削除するまでの日数
# CLAUDE.md テーブル設計: expires_at（30 日後自動削除）
_TTL_DAYS = 30

# 対応イベントタイプ（大文字に正規化して比較する）
_SUPPORTED_EVENT_TYPES = frozenset({"PURCHASE", "VIEW", "CLICK"})


class TransformError(ValueError):
    """
    変換処理中のバリデーション・変換エラー。

    ValueError のサブクラスとして定義することで、BatchProcessor の
    record_handler が例外をキャッチしてそのレコードを失敗扱いにできる。
    """

    pass


# ── パブリック API ─────────────────────────────────────────────


def transform_record(raw_data: dict[str, Any]) -> dict[str, Any]:
    """
    Kinesis から受け取ったデコード済み JSON データを DynamoDB アイテム形式に変換する。

    このメインエントリーポイントは複数の純粋関数を組み合わせて:
      1. スキーマバリデーション
      2. entity_id 正規化
      3. イベントタイプ別ビジネスロジック変換
      4. DynamoDB アイテム形式への組み立て（PK / SK / TTL / status）
    の 4 ステップを順番に実行する。

    Args:
        raw_data: Kinesis レコードの base64 デコード済み JSON（Python dict）

    Returns:
        DynamoDB の PutRequest.Item 形式の辞書（boto3 TypeSerializer 変換前の Python 型）

    Raises:
        TransformError: バリデーション失敗または未対応イベントタイプ
    """
    # ステップ 1: 必須フィールドのバリデーション
    _validate_schema(raw_data)

    # ステップ 2: entity_id の正規化（TYPE を大文字化）
    entity_id = _normalize_entity_id(raw_data["entity_id"])

    # ステップ 3: イベントタイプ別変換
    event_type = str(raw_data["event_type"]).strip().upper()
    enriched_payload = _apply_event_type_rules(event_type, raw_data)

    # ステップ 4: DynamoDB アイテム形式に組み立てる
    now_utc = datetime.now(timezone.utc)
    event_ts = _build_sort_key(raw_data["event_time"])
    expires_at = _calc_ttl(now_utc)

    return {
        # PK: エンティティ ID（例: USER#u123 → 正規化後 USER#u123）
        "entity_id": entity_id,
        # SK: イベントタイムスタンプ（例: EVENT#2024-01-15T12:00:00Z）
        "event_ts": event_ts,
        # GSI-1 PK: ステータス（PENDING で初期化、aggregator が PROCESSED に更新）
        "status": "PENDING",
        # イベントタイプ（GSI フィルタリングや集計に使用）
        "event_type": event_type,
        # 変換・エンリッチ済みのペイロード（イベントタイプ別フィールドを含む）
        "payload": enriched_payload,
        # transformer が変換を完了した時刻（UTC ISO 8601）
        "transformed_at": now_utc.isoformat(),
        # TTL: 30 日後の Unix タイムスタンプ（DynamoDB が自動削除する）
        "expires_at": expires_at,
    }


# ── バリデーション ─────────────────────────────────────────────


def _validate_schema(raw_data: dict[str, Any]) -> None:
    """
    Kinesis レコードの必須フィールドとイベントタイプを検証する。

    Args:
        raw_data: 検証対象の辞書

    Raises:
        TransformError: 必須フィールド欠落・不正な entity_id 形式・未対応イベントタイプ
    """
    # 必須フィールドの存在チェック
    required_fields = ["entity_id", "event_type", "event_time"]
    missing = [f for f in required_fields if f not in raw_data or raw_data[f] is None]
    if missing:
        raise TransformError(f"必須フィールドが欠落しています: {missing}")

    # entity_id の形式チェック: '<TYPE>#<ID>' 形式を要求する
    entity_id = str(raw_data["entity_id"]).strip()
    if "#" not in entity_id:
        raise TransformError(
            f"entity_id は '<TYPE>#<ID>' 形式で指定してください（例: USER#u123）: {entity_id!r}"
        )
    type_part, id_part = entity_id.split("#", 1)
    if not type_part.strip() or not id_part.strip():
        raise TransformError(
            f"entity_id の TYPE または ID 部分が空です: {entity_id!r}"
        )

    # event_type のサポートチェック
    event_type = str(raw_data["event_type"]).strip().upper()
    if event_type not in _SUPPORTED_EVENT_TYPES:
        raise TransformError(
            f"未対応のイベントタイプです: {event_type!r}（対応: {sorted(_SUPPORTED_EVENT_TYPES)}）"
        )


# ── entity_id 正規化 ───────────────────────────────────────────


def _normalize_entity_id(entity_id: str) -> str:
    """
    entity_id を正規化する。

    正規化ルール:
      - TYPE 部分を大文字化する（例: user#u123 → USER#u123）
      - TYPE・ID 部分の前後空白をトリムする
      - ID 部分の大文字化は行わない（ID は大文字小文字を区別する）

    Args:
        entity_id: '<TYPE>#<ID>' 形式の文字列

    Returns:
        正規化済みの entity_id（例: USER#u123）
    """
    type_part, id_part = str(entity_id).split("#", 1)
    return f"{type_part.strip().upper()}#{id_part.strip()}"


# ── ソートキー・TTL ヘルパー ───────────────────────────────────


def _build_sort_key(event_time: str) -> str:
    """
    DynamoDB SK の値を組み立てる。

    フォーマット: 'EVENT#<event_time>'（例: EVENT#2024-01-15T12:00:00Z）

    EVENT# プレフィックスを付与することで:
      - 同一 entity_id に複数の SK タイプが共存できる（拡張性）
      - SK の範囲クエリ（begins_with('EVENT#')）でイベントのみを絞り込める

    Args:
        event_time: ISO 8601 形式のタイムスタンプ文字列

    Returns:
        'EVENT#<event_time>' 形式の SK 文字列
    """
    return f"EVENT#{str(event_time).strip()}"


def _calc_ttl(base_time: datetime) -> int:
    """
    DynamoDB TTL 値（Unix タイムスタンプ）を計算する。

    Args:
        base_time: 起点となる datetime（UTC）

    Returns:
        _TTL_DAYS 日後の Unix タイムスタンプ（int）
    """
    return int((base_time + timedelta(days=_TTL_DAYS)).timestamp())


# ── イベントタイプ別変換ルール ─────────────────────────────────


def _apply_event_type_rules(event_type: str, raw_data: dict[str, Any]) -> dict[str, Any]:
    """
    イベントタイプに対応する変換ハンドラを選択して実行する。

    新しいイベントタイプを追加する場合は _SUPPORTED_EVENT_TYPES と
    このディスパッチテーブルの両方に追加する。

    Args:
        event_type: 大文字正規化済みのイベントタイプ（PURCHASE / VIEW / CLICK）
        raw_data: 生の Kinesis レコード辞書

    Returns:
        エンリッチ済みのペイロード辞書
    """
    handlers = {
        "PURCHASE": _transform_purchase,
        "VIEW": _transform_view,
        "CLICK": _transform_click,
    }
    # _validate_schema でサポートチェック済みのため KeyError は発生しない
    return handlers[event_type](raw_data)


def _transform_purchase(raw_data: dict[str, Any]) -> dict[str, Any]:
    """
    PURCHASE（購買）イベントの変換ルール。

    ビジネスロジック:
      - value（購買金額）は必須。0 未満は TransformError。
      - 金額帯（revenue_tier）を付与: LOW < 1000 / MEDIUM < 10000 / HIGH >= 10000
      - 通貨（currency）は metadata から取得し、未指定は JPY をデフォルトとする。

    Args:
        raw_data: 生の Kinesis レコード辞書（event_type == "PURCHASE"）

    Returns:
        エンリッチ済みペイロード辞書

    Raises:
        TransformError: value が欠落・数値でない・0 未満
    """
    value = raw_data.get("value")
    if value is None:
        raise TransformError("PURCHASE イベントには value（購買金額）が必須です")

    try:
        value = float(value)
    except (TypeError, ValueError):
        raise TransformError(f"value は数値で指定してください: {value!r}")

    if value < 0:
        raise TransformError(f"PURCHASE の value は 0 以上の値を指定してください: {value}")

    # 購買金額帯の分類: 集計クエリやダッシュボードフィルターに使用する
    if value < 1000:
        revenue_tier = "LOW"
    elif value < 10_000:
        revenue_tier = "MEDIUM"
    else:
        revenue_tier = "HIGH"

    metadata = raw_data.get("metadata") or {}
    return {
        "event_type": "PURCHASE",
        "value": value,
        "revenue_tier": revenue_tier,
        "currency": metadata.get("currency", "JPY"),
        "product_id": metadata.get("product_id"),
        "category": metadata.get("category"),
    }


def _transform_view(raw_data: dict[str, Any]) -> dict[str, Any]:
    """
    VIEW（ページ閲覧）イベントの変換ルール。

    ビジネスロジック:
      - page_path は metadata から取得。未指定は "/" をデフォルトとする。
      - duration_seconds（滞在時間）は任意。負の値は 0 にクランプする。
      - referrer（参照元 URL）は任意。

    Args:
        raw_data: 生の Kinesis レコード辞書（event_type == "VIEW"）

    Returns:
        エンリッチ済みペイロード辞書
    """
    metadata = raw_data.get("metadata") or {}

    # duration_seconds の正規化: 負の値はデータ品質問題として 0 にクランプする
    duration = metadata.get("duration_seconds")
    if duration is not None:
        try:
            duration = max(0.0, float(duration))
        except (TypeError, ValueError):
            duration = None

    return {
        "event_type": "VIEW",
        "page_path": metadata.get("page_path", "/"),
        "duration_seconds": duration,
        "referrer": metadata.get("referrer"),
        "user_agent": metadata.get("user_agent"),
    }


def _transform_click(raw_data: dict[str, Any]) -> dict[str, Any]:
    """
    CLICK（クリック）イベントの変換ルール。

    ビジネスロジック:
      - element_id: クリックされた DOM 要素の ID（metadata から取得、未指定は "unknown"）
      - click_x / click_y: クリック座標（任意。int に変換する）
      - page_path: クリック発生ページ（metadata から取得）

    Args:
        raw_data: 生の Kinesis レコード辞書（event_type == "CLICK"）

    Returns:
        エンリッチ済みペイロード辞書
    """
    metadata = raw_data.get("metadata") or {}

    # クリック座標を整数に変換する（フロントエンドが float で送ってくる場合がある）
    def _to_int_or_none(val: Any) -> int | None:
        try:
            return int(float(val)) if val is not None else None
        except (TypeError, ValueError):
            return None

    return {
        "event_type": "CLICK",
        "element_id": metadata.get("element_id", "unknown"),
        "click_x": _to_int_or_none(metadata.get("click_x")),
        "click_y": _to_int_or_none(metadata.get("click_y")),
        "page_path": metadata.get("page_path", "/"),
        "target_url": metadata.get("target_url"),
    }
