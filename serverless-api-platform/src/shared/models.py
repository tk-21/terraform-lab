# src/shared/models.py
#
# Pydantic データモデル定義。
# API リクエスト・レスポンスのバリデーションと DynamoDB のデータ構造を定義する。
#
# Lambda Powertools の APIGatewayRestResolver(enable_validation=True) と組み合わせると、
# ハンドラーの引数に型アノテーションを付けるだけで自動バリデーションが行われる。

from datetime import datetime, timezone
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field, field_validator


class ItemStatus(str, Enum):
    """アイテムのステータス。DynamoDB の status GSI で使用する。"""

    ACTIVE = "ACTIVE"
    ARCHIVED = "ARCHIVED"


class CreateItemRequest(BaseModel):
    """
    POST /items のリクエストボディ。
    必須フィールド: name
    オプション: description
    """

    name: str = Field(
        ...,
        min_length=1,
        max_length=200,
        description="アイテム名。1〜200文字。",
    )
    description: Optional[str] = Field(
        default=None,
        max_length=2000,
        description="アイテムの説明。最大2000文字。",
    )

    @field_validator("name")
    @classmethod
    def name_must_not_be_blank(cls, v: str) -> str:
        """空白のみの名前を拒否する。"""
        if not v.strip():
            raise ValueError("name は空白のみにできません")
        return v.strip()


class UpdateItemRequest(BaseModel):
    """
    PUT /items/{id} のリクエストボディ。
    name と description の両方がオプション（PATCH 的な部分更新）。
    ただし、少なくとも1フィールドは指定必須。
    """

    name: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=200,
    )
    description: Optional[str] = Field(
        default=None,
        max_length=2000,
    )
    status: Optional[ItemStatus] = Field(
        default=None,
        description="ステータス変更。ARCHIVED にすると TTL が設定される。",
    )

    def model_post_init(self, __context) -> None:
        """少なくとも1フィールドが指定されていることを検証する。"""
        if self.name is None and self.description is None and self.status is None:
            raise ValueError("name, description, status のいずれかを指定してください")


class Item(BaseModel):
    """
    DynamoDB に保存されるアイテムの完全なデータモデル。
    レスポンスの data フィールドにはこのモデルを使用する。
    """

    item_id: str = Field(description="アイテム UUID")
    user_id: str = Field(description="所有者のユーザー ID（Cognito Sub）")
    name: str
    description: Optional[str] = None
    status: ItemStatus = ItemStatus.ACTIVE
    created_at: str = Field(description="ISO8601 UTC 形式")
    updated_at: str = Field(description="ISO8601 UTC 形式")
    expires_at: Optional[int] = Field(
        default=None,
        description="TTL（UNIX タイムスタンプ）。ARCHIVED 時に設定される。",
    )

    @classmethod
    def from_dynamodb(cls, item: dict) -> "Item":
        """
        DynamoDB から取得したアイテムを Item モデルに変換する。
        DynamoDB の PK/SK プレフィックス（ITEM#）を除去する。
        """
        return cls(
            item_id=item.get("item_id", ""),
            user_id=item.get("user_id", ""),
            name=item.get("name", ""),
            description=item.get("description"),
            status=ItemStatus(item.get("status", "ACTIVE")),
            created_at=item.get("created_at", ""),
            updated_at=item.get("updated_at", ""),
            expires_at=item.get("expires_at"),
        )

    def to_dynamodb(self) -> dict:
        """
        Item モデルを DynamoDB 保存用の形式に変換する。
        Single Table Design に従い PK/SK を設定する。
        """
        item = {
            "PK": f"ITEM#{self.item_id}",
            "SK": f"ITEM#{self.item_id}",
            "item_id": self.item_id,
            "user_id": self.user_id,
            "name": self.name,
            "status": self.status.value,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }
        if self.description is not None:
            item["description"] = self.description
        if self.expires_at is not None:
            item["expires_at"] = self.expires_at
        return item
