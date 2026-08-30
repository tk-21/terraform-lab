"""Amazon SNS を使って高優先度の Security Hub Finding を通知する。"""

import logging
import os
from datetime import datetime, timedelta, timezone

import boto3

logger = logging.getLogger(__name__)

JST = timezone(timedelta(hours=9))
MAX_SNS_SUBJECT_LENGTH = 100


class SnsNotifier:
    """Amazon SNS Topic へセキュリティアラートを通知するクライアント。"""

    def __init__(self) -> None:
        """SNS クライアントと通知先 Topic ARN を初期化する。"""
        # iam: sns:Publish
        self._sns_client = boto3.client("sns")
        self._topic_arn = os.environ.get("SNS_TOPIC_ARN", "")

    def notify(
        self,
        title: str,
        severity: str,
        resource_id: str,
        triage_result: dict,
    ) -> bool:
        """Security Hub Finding の SNS 通知を送信する。"""
        try:
            if not self._topic_arn:
                raise RuntimeError("SNS_TOPIC_ARN が設定されていません")

            self._sns_client.publish(
                TopicArn=self._topic_arn,
                Subject=self._build_subject(title=title, severity=severity),
                Message=self._build_message(
                    title=title,
                    severity=severity,
                    resource_id=resource_id,
                    triage_result=triage_result,
                ),
            )
            logger.info("SNS 通知送信成功: title=%s", title)
            return True
        except Exception as error:
            # 通知失敗はトリアージ処理全体を止めない
            logger.error("SNS 通知の送信に失敗しました: %s", error, exc_info=True)
            return False

    @staticmethod
    def _build_subject(title: str, severity: str) -> str:
        """SNS の 100 文字制限に収まる件名を作成する。"""
        subject = f"Security Hub [{severity}]: {title}"
        return subject[:MAX_SNS_SUBJECT_LENGTH]

    @staticmethod
    def _build_message(
        title: str,
        severity: str,
        resource_id: str,
        triage_result: dict,
    ) -> str:
        """メールなどの SNS 購読先で読めるプレーンテキスト通知を作成する。"""
        detected_at = datetime.now(JST).strftime("%Y-%m-%d %H:%M:%S JST")
        return (
            "Security Hub アラート\n"
            "==================\n"
            f"検出名: {title}\n"
            f"重大度: {severity}\n"
            f"リソース: {resource_id}\n"
            f"AI判定: {triage_result.get('verdict', '監視継続')}"
            f"（リスクスコア: {triage_result.get('risk_score', 5)}/10）\n"
            f"理由: {triage_result.get('reason', '')}\n"
            f"推奨アクション: {triage_result.get('action', '')}\n"
            f"検出時刻: {detected_at}\n"
        )
