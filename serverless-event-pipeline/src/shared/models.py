"""
共有 Pydantic データモデル
全 Lambda で共通利用するイベントスキーマを定義する。

モデル階層:
  InputPayload  → S3 から読み込んだ生データのスキーマ（バリデーション・正規化）
  EventRecord   → DynamoDB に格納するレコードのスキーマ（ingestor が生成）
"""

from datetime import datetime, timezone
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field, field_validator


class EventStatus(str, Enum):
    PENDING = "PENDING"
    PROCESSED = "PROCESSED"
    FAILED = "FAILED"


class InputPayload(BaseModel):
    """
    S3 入力データ（JSON / CSV）のスキーマ定義。

    バリデーション:
    - entity_id: '<TYPE>#<ID>' 形式（例: USER#u123、PRODUCT#p001）
    - event_time: ISO 8601 形式の日時文字列（タイムゾーン付き推奨）
    - value: 0 以上の数値（任意）

    正規化:
    - 文字列フィールドの先頭・末尾空白はトリムされる（strip_whitespace=True）
    """

    entity_id: str = Field(
        ...,
        min_length=3,
        description="エンティティ ID。'<TYPE>#<ID>' の形式（例: USER#u123）",
    )
    event_type: str = Field(
        ...,
        min_length=1,
        description="イベント種別（例: purchase, click, view）",
    )
    event_time: str = Field(
        ...,
        description="イベント発生時刻。ISO 8601 形式（例: 2024-01-15T12:00:00Z）",
    )
    value: Optional[float] = Field(
        None,
        ge=0,
        description="数値データ（0 以上）。購買金額・スコアなど任意の数値。",
    )
    metadata: dict = Field(
        default_factory=dict,
        description="拡張フィールド。任意のキーバリューペアを格納できる。",
    )

    @field_validator("entity_id")
    @classmethod
    def validate_entity_id_format(cls, v: str) -> str:
        """entity_id が '<TYPE>#<ID>' 形式であることを検証する。"""
        v = v.strip()
        if "#" not in v:
            raise ValueError(
                f"entity_id は '<TYPE>#<ID>' の形式で指定してください（例: USER#u123）: {v}"
            )
        type_part, id_part = v.split("#", 1)
        if not type_part or not id_part:
            raise ValueError(
                f"entity_id の TYPE または ID が空です: {v}"
            )
        return v

    @field_validator("event_type")
    @classmethod
    def validate_event_type(cls, v: str) -> str:
        """event_type の前後空白をトリムする。"""
        return v.strip()

    @field_validator("event_time")
    @classmethod
    def validate_event_time_format(cls, v: str) -> str:
        """event_time が ISO 8601 形式であることを検証し、タイムゾーンを正規化する。"""
        v = v.strip()
        try:
            # 'Z' を '+00:00' に変換して fromisoformat でパース可能にする
            datetime.fromisoformat(v.replace("Z", "+00:00"))
        except ValueError as e:
            raise ValueError(
                f"event_time は ISO 8601 形式で指定してください（例: 2024-01-15T12:00:00Z）: {v}"
            ) from e
        return v

    def event_datetime(self) -> datetime:
        """event_time を UTC タイムゾーン付き datetime オブジェクトに変換する。"""
        dt = datetime.fromisoformat(self.event_time.replace("Z", "+00:00"))
        # タイムゾーン情報がない場合は UTC として扱う
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)


class EventRecord(BaseModel):
    """
    DynamoDB に格納するイベントレコード。

    テーブル設計（CLAUDE.md 準拠）:
      PK: entity_id  例: USER#u123
      SK: event_ts   例: EVENT#2024-01-15T12:00:00Z

    GSI-1 (status-index):
      PK: status     PENDING / PROCESSED / FAILED
      SK: event_ts

    TTL: expires_at（30 日後に自動削除）
    Streams: aggregator Lambda のトリガーに使用
    """

    entity_id: str = Field(..., description="DynamoDB PK: エンティティ ID（例: USER#u123）")
    event_ts: str = Field(..., description="DynamoDB SK: イベントタイムスタンプ（例: EVENT#2024-01-15T12:00:00Z）")
    status: EventStatus = Field(default=EventStatus.PENDING, description="処理ステータス（GSI-1 PK）")
    payload: dict = Field(default_factory=dict, description="イベントデータ本体（InputPayload の内容）")
    expires_at: Optional[int] = Field(None, description="TTL: Unix タイムスタンプ（30 日後）")

    # トレーサビリティ: どの S3 ファイルから取り込まれたかを記録する
    source_bucket: str = Field(..., description="取り込み元 S3 バケット名")
    source_key: str = Field(..., description="取り込み元 S3 オブジェクトキー")
    ingested_at: str = Field(..., description="DynamoDB への書き込み時刻（UTC ISO 8601 形式）")
