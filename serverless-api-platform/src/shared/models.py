# src/shared/models.py
#
# Pydantic v2 データモデル定義。
# API リクエスト・レスポンスのバリデーションと DynamoDB データ構造を定義する。
#
# CLAUDE.md 命名:
#   ItemCreate   = 作成リクエスト（POST /items）
#   ItemUpdate   = 更新リクエスト（PUT /items/{id}）
#   ItemResponse = レスポンス用モデル（DynamoDB 取得データを API 向けに整形）

from datetime import datetime, timezone
from typing import Literal, Optional

from pydantic import BaseModel, Field, field_validator, model_validator


class ItemCreate(BaseModel):
    """
    POST /items のリクエストボディ。
    バリデーション規則:
      - name: 必須、1〜100文字（空白のみ不可）
      - description: 任意、最大1000文字
      - expires_days: 任意、1〜365日（指定時は作成直後に expires_at を設定）
    """

    name: str = Field(
        ...,
        min_length=1,
        max_length=100,
        description="アイテム名。1〜100文字。",
    )
    description: Optional[str] = Field(
        default=None,
        max_length=1000,
        description="アイテムの説明。最大1000文字。",
    )
    expires_days: Optional[int] = Field(
        default=None,
        ge=1,
        le=365,
        description="有効期限（日数）。指定時は作成時点から expires_days 日後に expires_at を設定する。",
    )

    @field_validator("name")
    @classmethod
    def name_must_not_be_blank(cls, v: str) -> str:
        """空白のみの名前を拒否する（例: '   ' は無効）。"""
        if not v.strip():
            raise ValueError("name は空白のみにできません")
        return v.strip()


class ItemUpdate(BaseModel):
    """
    PUT /items/{id} のリクエストボディ。
    name / description / status の部分更新に対応する（PATCH 的な挙動）。
    少なくとも1フィールドの指定が必須。
    """

    name: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=100,
        description="アイテム名。変更しない場合は null または省略。",
    )
    description: Optional[str] = Field(
        default=None,
        max_length=1000,
        description="アイテムの説明。変更しない場合は null または省略。",
    )
    # Literal で許容値を明示。 Pydantic が自動でバリデーションする。
    status: Optional[Literal["ACTIVE", "ARCHIVED"]] = Field(
        default=None,
        description="ステータス。ARCHIVED にすると TTL が設定される。",
    )

    @model_validator(mode="after")
    def at_least_one_field_required(self) -> "ItemUpdate":
        """全フィールドが None の場合は更新する内容がないためエラー。"""
        if self.name is None and self.description is None and self.status is None:
            raise ValueError("name, description, status のいずれかを指定してください")
        return self


class ItemResponse(BaseModel):
    """
    レスポンス用アイテムモデル。DynamoDB から取得したデータを API 向けに整形する。
    DynamoDB の内部キー（PK / SK）は除外し、クライアント向けフィールドのみを公開する。
    """

    item_id: str = Field(description="アイテム UUID")
    user_id: str = Field(description="所有者のユーザー ID（Cognito sub クレーム）")
    name: str
    description: Optional[str] = None
    # Literal を使用して許容値をスキーマに明示する
    status: Literal["ACTIVE", "ARCHIVED"] = "ACTIVE"
    created_at: str = Field(description="作成日時（ISO8601 UTC）")
    updated_at: str = Field(description="最終更新日時（ISO8601 UTC）")
    expires_at: Optional[int] = Field(
        default=None,
        description="TTL（UNIX タイムスタンプ秒）。ARCHIVED または expires_days 指定時に設定。",
    )

    @classmethod
    def from_dynamodb(cls, item: dict) -> "ItemResponse":
        """
        DynamoDB から取得したアイテム dict を ItemResponse に変換する。
        PK / SK はクライアントに不要なため除外する。
        """
        return cls(
            item_id=item["item_id"],
            user_id=item["user_id"],
            name=item["name"],
            description=item.get("description"),
            status=item.get("status", "ACTIVE"),
            created_at=item["created_at"],
            updated_at=item["updated_at"],
            expires_at=int(item["expires_at"]) if item.get("expires_at") is not None else None,
        )

    def to_dynamodb(self) -> dict:
        """
        ItemResponse を DynamoDB 保存用の形式に変換する。
        Single Table Design に従い PK / SK を ITEM#<uuid> 形式で設定する。
        """
        record: dict = {
            "PK": f"ITEM#{self.item_id}",
            "SK": f"ITEM#{self.item_id}",
            "item_id": self.item_id,
            "user_id": self.user_id,
            "name": self.name,
            "status": self.status,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }
        # None のフィールドは DynamoDB に書き込まない（不要な null 属性を排除）
        if self.description is not None:
            record["description"] = self.description
        if self.expires_at is not None:
            # DynamoDB の Number 型として保存する（TTL は整数 UNIX タイムスタンプ）
            from decimal import Decimal
            record["expires_at"] = Decimal(str(self.expires_at))
        return record
