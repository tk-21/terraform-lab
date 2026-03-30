# src/shared/repository.py
#
# DynamoDB アクセス層。
# Lambda 関数から直接 boto3 を呼び出すのではなく、
# このクラスを経由させることでテスタビリティを確保する。
#
# 重要: DynamoDB の Scan API は使用禁止（CLAUDE.md の禁止事項）。
# 一覧取得は必ず GSI を使用した Query で行うこと。

import os
from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional

import boto3
from aws_lambda_powertools import Logger, Tracer
from boto3.dynamodb.conditions import Key

from .exceptions import ItemNotFoundError
from .models import Item, ItemStatus

logger = Logger()
tracer = Tracer()

# テーブル名は環境変数から取得する。
# ハードコードは CLAUDE.md の禁止事項。
TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]


class ItemRepository:
    """
    DynamoDB の Items テーブルに対する CRUD 操作を提供するリポジトリクラス。
    テストではこのクラスをモックすることで Lambda ロジックを単体テストできる。
    """

    def __init__(self):
        self._dynamodb = boto3.resource("dynamodb")
        self._table = self._dynamodb.Table(TABLE_NAME)

    @tracer.capture_method
    def get(self, item_id: str) -> Item:
        """
        アイテムを取得する。存在しない場合は ItemNotFoundError を発生させる。

        Args:
            item_id: アイテム UUID

        Raises:
            ItemNotFoundError: アイテムが存在しない場合
        """
        response = self._table.get_item(
            Key={
                "PK": f"ITEM#{item_id}",
                "SK": f"ITEM#{item_id}",
            }
        )

        item = response.get("Item")
        if not item:
            raise ItemNotFoundError(item_id)

        return Item.from_dynamodb(item)

    @tracer.capture_method
    def list_by_user(
        self,
        user_id: str,
        limit: int = 20,
        last_evaluated_key: Optional[dict] = None,
    ) -> tuple[list[Item], Optional[dict]]:
        """
        ユーザー別アイテム一覧を取得する（GSI-1: user-index を使用）。

        DynamoDB の Scan ではなく Query を使用することで、
        フルスキャンによるコスト増大を防ぐ。

        Args:
            user_id: 所有者のユーザー ID
            limit: 1回のクエリで取得する最大件数
            last_evaluated_key: ページネーションの継続キー

        Returns:
            (アイテムリスト, 次ページの ExclusiveStartKey)
        """
        kwargs = {
            "IndexName": "user-index",
            "KeyConditionExpression": Key("user_id").eq(user_id),
            "Limit": limit,
            # created_at の降順（新しい順）で返す
            "ScanIndexForward": False,
        }

        if last_evaluated_key:
            kwargs["ExclusiveStartKey"] = last_evaluated_key

        response = self._table.query(**kwargs)

        items = [Item.from_dynamodb(i) for i in response.get("Items", [])]
        next_key = response.get("LastEvaluatedKey")

        return items, next_key

    @tracer.capture_method
    def create(self, item: Item) -> Item:
        """
        新しいアイテムを作成する。
        条件式で重複作成を防ぐ（PK が存在しない場合のみ書き込み）。
        """
        self._table.put_item(
            Item=item.to_dynamodb(),
            # 同一 PK が既に存在する場合は ConditionalCheckFailedException を発生させる
            ConditionExpression="attribute_not_exists(PK)",
        )
        return item

    @tracer.capture_method
    def update(
        self,
        item_id: str,
        user_id: str,
        name: Optional[str] = None,
        description: Optional[str] = None,
        status: Optional[ItemStatus] = None,
    ) -> Item:
        """
        アイテムを部分更新する。
        所有者チェック付き（他ユーザーのアイテムは更新不可）。

        Raises:
            ItemNotFoundError: アイテムが存在しない場合
            ForbiddenError: 所有者でない場合
        """
        now = datetime.now(timezone.utc).isoformat()

        update_expressions = ["#updated_at = :updated_at"]
        expression_names = {"#updated_at": "updated_at"}
        expression_values: dict = {":updated_at": now, ":user_id": user_id}

        if name is not None:
            update_expressions.append("#name = :name")
            expression_names["#name"] = "name"
            expression_values[":name"] = name

        if description is not None:
            update_expressions.append("#description = :description")
            expression_names["#description"] = "description"
            expression_values[":description"] = description

        if status is not None:
            update_expressions.append("#status = :status")
            expression_names["#status"] = "status"
            expression_values[":status"] = status.value

        response = self._table.update_item(
            Key={
                "PK": f"ITEM#{item_id}",
                "SK": f"ITEM#{item_id}",
            },
            UpdateExpression="SET " + ", ".join(update_expressions),
            ExpressionAttributeNames=expression_names,
            ExpressionAttributeValues=expression_values,
            # 所有者チェック: 自分のアイテムのみ更新可能
            ConditionExpression="attribute_exists(PK) AND user_id = :user_id",
            ReturnValues="ALL_NEW",
        )

        return Item.from_dynamodb(response["Attributes"])

    @tracer.capture_method
    def delete(self, item_id: str, user_id: str) -> None:
        """
        アイテムを削除する。
        所有者チェック付き（他ユーザーのアイテムは削除不可）。

        Raises:
            ItemNotFoundError: アイテムが存在しない場合
            ForbiddenError: 所有者でない場合
        """
        self._table.delete_item(
            Key={
                "PK": f"ITEM#{item_id}",
                "SK": f"ITEM#{item_id}",
            },
            # 所有者チェック
            ConditionExpression="attribute_exists(PK) AND user_id = :user_id",
            ExpressionAttributeValues={":user_id": user_id},
        )
