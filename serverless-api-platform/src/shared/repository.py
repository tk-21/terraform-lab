# src/shared/repository.py
#
# DynamoDB アクセス層。
# Lambda 関数から直接 boto3 を呼び出すのではなく、
# このクラスを経由させることでテスタビリティを確保する。
#
# 重要: DynamoDB の Scan API は使用禁止（CLAUDE.md の禁止事項）。
# 一覧取得は必ず GSI を使用した Query で行うこと。
#
# 所有者チェック（user_id の照合）はハンドラー層で行う設計とした理由:
#   - リポジトリはデータアクセスに専念し、ビジネスロジックを持たせない
#   - DynamoDB の ConditionExpression で user_id チェックを行うと
#     ItemNotFoundError と ForbiddenError を区別できない（どちらも
#     ConditionalCheckFailedException になる）ため、
#     先に GetItem で取得・照合する方が明確なエラーレスポンスを返せる

import os
from datetime import datetime, timezone, timedelta
from decimal import Decimal
from typing import Optional

import boto3
from aws_lambda_powertools import Logger, Tracer
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from .exceptions import ItemAlreadyExistsError, ItemNotFoundError
from .models import ItemResponse

logger = Logger()
tracer = Tracer()

# テーブル名は環境変数から取得する。ハードコード禁止（CLAUDE.md）。
TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]


class ItemRepository:
    """
    DynamoDB Items テーブルに対する CRUD 操作を提供する。
    テストではこのクラスをモックすることで Lambda ロジックを単体テストできる。
    """

    def __init__(self) -> None:
        self._dynamodb = boto3.resource("dynamodb")
        self._table = self._dynamodb.Table(TABLE_NAME)

    @tracer.capture_method
    def get(self, item_id: str) -> ItemResponse:
        """
        アイテムを1件取得する。
        存在しない場合は ItemNotFoundError を発生させる。
        所有者チェックはハンドラー層で行うこと（get → check → action の順）。

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
        return ItemResponse.from_dynamodb(item)

    @tracer.capture_method
    def list_by_user(
        self,
        user_id: str,
        limit: int = 20,
        last_evaluated_key: Optional[dict] = None,
    ) -> tuple[list[ItemResponse], Optional[dict]]:
        """
        ユーザー別アイテム一覧を GSI-1（user-index）で取得する。
        フルスキャンではなく Query を使用することでコストを抑える。

        Args:
            user_id: 所有者のユーザー ID（Cognito sub）
            limit: 1回のクエリで取得する最大件数（最大100）
            last_evaluated_key: ページネーションの継続キー（ExclusiveStartKey）

        Returns:
            (アイテムリスト, 次ページの ExclusiveStartKey or None)
        """
        kwargs: dict = {
            "IndexName": "user-index",
            # GSI-1 のパーティションキー（user_id）でクエリする
            "KeyConditionExpression": Key("user_id").eq(user_id),
            "Limit": limit,
            # ScanIndexForward=False で created_at 降順（新しい順）に取得する
            "ScanIndexForward": False,
        }
        if last_evaluated_key:
            kwargs["ExclusiveStartKey"] = last_evaluated_key

        response = self._table.query(**kwargs)

        items = [ItemResponse.from_dynamodb(i) for i in response.get("Items", [])]
        next_key = response.get("LastEvaluatedKey")
        return items, next_key

    @tracer.capture_method
    def create(self, item: ItemResponse) -> ItemResponse:
        """
        新しいアイテムを作成する。
        ConditionExpression で同一 PK の重複書き込みを防ぐ。

        Raises:
            ItemAlreadyExistsError: 同一 item_id が既に存在する場合
        """
        try:
            self._table.put_item(
                Item=item.to_dynamodb(),
                # PK が存在しない場合のみ書き込む（UUID 衝突の二重防止）
                ConditionExpression="attribute_not_exists(PK)",
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                # UUID 衝突は極めてまれだが、適切なエラーを返す
                raise ItemAlreadyExistsError(item.item_id) from e
            raise
        return item

    @tracer.capture_method
    def update(
        self,
        item_id: str,
        name: Optional[str] = None,
        description: Optional[str] = None,
        status: Optional[str] = None,
    ) -> ItemResponse:
        """
        アイテムを部分更新する。
        所有者チェックはハンドラー層で実施済みであることを前提とする。

        Raises:
            ItemNotFoundError: アイテムが存在しない場合
        """
        now = datetime.now(timezone.utc).isoformat()

        # 更新するフィールドを動的に組み立てる
        update_parts = ["#updated_at = :updated_at"]
        expr_names: dict = {"#updated_at": "updated_at"}
        expr_values: dict = {":updated_at": now}

        if name is not None:
            update_parts.append("#name = :name")
            expr_names["#name"] = "name"
            expr_values[":name"] = name

        if description is not None:
            update_parts.append("#description = :description")
            expr_names["#description"] = "description"
            expr_values[":description"] = description

        if status is not None:
            update_parts.append("#status = :status")
            expr_names["#status"] = "status"
            expr_values[":status"] = status
            # ARCHIVED への変更時は expires_at（30日後）を設定する
            if status == "ARCHIVED":
                expires_at = int(
                    (datetime.now(timezone.utc) + timedelta(days=30)).timestamp()
                )
                update_parts.append("#expires_at = :expires_at")
                expr_names["#expires_at"] = "expires_at"
                expr_values[":expires_at"] = Decimal(str(expires_at))

        try:
            response = self._table.update_item(
                Key={
                    "PK": f"ITEM#{item_id}",
                    "SK": f"ITEM#{item_id}",
                },
                UpdateExpression="SET " + ", ".join(update_parts),
                ExpressionAttributeNames=expr_names,
                ExpressionAttributeValues=expr_values,
                # PK の存在確認のみ（所有者チェックはハンドラー層で実施済み）
                ConditionExpression="attribute_exists(PK)",
                ReturnValues="ALL_NEW",
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ItemNotFoundError(item_id) from e
            raise

        return ItemResponse.from_dynamodb(response["Attributes"])

    @tracer.capture_method
    def delete(self, item_id: str) -> None:
        """
        アイテムを論理削除する。

        物理削除ではなく論理削除（status = ARCHIVED）を採用した理由:
          - DynamoDB Streams で変更イベントを S3 に監査ログとして保存するため、
            物理削除でも DELETE イベントが記録されるが、
            論理削除の方が「いつ削除されたか」をアイテム自体に残せる
          - TTL（expires_at = 30日後）で DynamoDB が自動削除するため、
            ストレージコストも長期的には増加しない
          - PITR（ポイントインタイムリカバリ）での復元が容易

        所有者チェックはハンドラー層で実施済みであることを前提とする。

        Raises:
            ItemNotFoundError: アイテムが存在しない場合
        """
        now = datetime.now(timezone.utc)
        # 論理削除から30日後に DynamoDB TTL が自動削除する
        expires_at = Decimal(str(int((now + timedelta(days=30)).timestamp())))

        try:
            self._table.update_item(
                Key={
                    "PK": f"ITEM#{item_id}",
                    "SK": f"ITEM#{item_id}",
                },
                UpdateExpression=(
                    "SET #status = :status, #expires_at = :expires_at, #updated_at = :updated_at"
                ),
                ExpressionAttributeNames={
                    "#status": "status",
                    "#expires_at": "expires_at",
                    "#updated_at": "updated_at",
                },
                ExpressionAttributeValues={
                    ":status": "ARCHIVED",
                    ":expires_at": expires_at,
                    ":updated_at": now.isoformat(),
                },
                ConditionExpression="attribute_exists(PK)",
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ItemNotFoundError(item_id) from e
            raise
