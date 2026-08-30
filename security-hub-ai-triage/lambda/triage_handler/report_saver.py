"""
report_saver - Security Hub Findings のフルレポートを S3 に保存するモジュール

トリアージ結果と元の Finding を JSON 形式で S3 に永続化する。
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3

logger = logging.getLogger(__name__)

JST = timezone(timedelta(hours=9))


class ReportSaver:
    """Security Hub Findings のトリアージレポートを S3 に保存するクラス。"""

    def __init__(self) -> None:
        """S3 クライアントとバケット名を初期化する。"""
        # iam: s3:PutObject
        self._s3 = boto3.client("s3")
        self._bucket_name = os.environ.get("S3_BUCKET_NAME", "")
        self._model_id = os.environ.get("BEDROCK_MODEL_ID", "jp.anthropic.claude-haiku-4-5-20251001-v1:0")

    def save(self, finding: dict, triage_result: dict) -> str:
        """
        Finding とトリアージ結果を JSON 形式で S3 に保存する。

        Args:
            finding: Security Hub Finding の原文 dict
            triage_result: Bedrock トリアージ結果（verdict, reason, action, risk_score）

        Returns:
            str: 保存した S3 オブジェクトキー
        """
        finding_id = finding.get("Id", "unknown")
        now_jst = datetime.now(JST)
        processed_at = now_jst.isoformat()

        object_key = self._build_object_key(finding_id=finding_id, now=now_jst)

        report = {
            "original_finding": finding,
            "triage_result": triage_result,
            "processed_at": processed_at,
            "model_id": self._model_id,
        }

        # iam: s3:PutObject
        # フルレポートを S3 に保存（キー: findings/{year}/{month}/{day}/{finding_id}.json）
        self._s3.put_object(
            Bucket=self._bucket_name,
            Key=object_key,
            Body=json.dumps(report, ensure_ascii=False, default=str),
            ContentType="application/json",
        )

        logger.info("レポートを S3 に保存しました: s3://%s/%s", self._bucket_name, object_key)
        return object_key

    def _build_object_key(self, finding_id: str, now: datetime) -> str:
        """
        S3 オブジェクトキーを生成する。

        Finding ID の `/` や `:` をハイフンに置換し、ファイル名として安全な文字列にする。

        Args:
            finding_id: Security Hub FindingId（ARN 形式）
            now: 保存日時（JST）

        Returns:
            str: S3 オブジェクトキー（例: findings/2025/08/01/arn-aws-...json）
        """
        # finding_id（ARN 形式）の / や : を - に置換してファイル名として安全にする
        safe_finding_id = finding_id.replace("/", "-").replace(":", "-")

        year = now.strftime("%Y")
        month = now.strftime("%m")
        day = now.strftime("%d")

        return f"findings/{year}/{month}/{day}/{safe_finding_id}.json"
