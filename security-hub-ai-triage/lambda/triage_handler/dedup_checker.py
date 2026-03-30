"""
dedup_checker - DynamoDB を使った Finding 重複排除モジュール

同一 FindingId の処理済み確認・記録を行い、
Lambda の無駄な再処理を防ぐ（TTL: 7日）。
"""

import logging
import os
from datetime import datetime, timedelta, timezone

import boto3

logger = logging.getLogger(__name__)

JST = timezone(timedelta(hours=9))
# TTL: 処理日時から 7日後
TTL_DAYS = 7


class DedupChecker:
    """DynamoDB を使って Security Hub Findings の重複処理を防ぐクラス。"""

    def __init__(self) -> None:
        """DynamoDB クライアントとテーブル名を初期化する。"""
        # iam: dynamodb:GetItem, dynamodb:PutItem
        self._dynamodb = boto3.client("dynamodb")
        self._table_name = os.environ.get("DYNAMODB_TABLE_NAME", "")

    def is_processed(self, finding_id: str) -> bool:
        """
        指定した FindingId が処理済みかどうかを確認する。

        Args:
            finding_id: 確認対象の Security Hub FindingId（ARN 形式）

        Returns:
            bool: 処理済みなら True、未処理なら False
        """
        # iam: dynamodb:GetItem
        # FindingId をキーに過去処理済みかチェック（TTL: 7日）
        response = self._dynamodb.get_item(
            TableName=self._table_name,
            Key={"finding_id": {"S": finding_id}},
            ProjectionExpression="finding_id",
        )
        return "Item" in response

    def mark_processed(
        self,
        finding_id: str,
        verdict: str,
        risk_score: int,
    ) -> None:
        """
        Finding を処理済みとして DynamoDB に記録する。

        TTL は処理日時 + 7日のエポック秒として設定する。

        Args:
            finding_id: 記録対象の Security Hub FindingId（ARN 形式）
            verdict: AI トリアージの判定結果
            risk_score: AI トリアージのリスクスコア（1〜10）
        """
        now_jst = datetime.now(JST)
        processed_at = now_jst.isoformat()
        # TTL: 現在時刻 + 7日のエポック秒
        ttl_epoch = int((now_jst + timedelta(days=TTL_DAYS)).timestamp())

        # iam: dynamodb:PutItem
        # 処理済みとして記録（同一 FindingId の再処理を TTL 内で防ぐ）
        self._dynamodb.put_item(
            TableName=self._table_name,
            Item={
                "finding_id":   {"S": finding_id},
                "processed_at": {"S": processed_at},
                "verdict":      {"S": verdict},
                "risk_score":   {"N": str(risk_score)},
                "ttl":          {"N": str(ttl_epoch)},
            },
        )
        logger.info(
            "処理済みとして記録: finding_id=%s verdict=%s ttl=%d",
            finding_id, verdict, ttl_epoch
        )
