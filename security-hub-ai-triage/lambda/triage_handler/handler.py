"""
triage_handler - Security Hub Findings の自動トリアージメインエントリーポイント

EventBridge から Security Hub Findings を受け取り、Bedrock で AI トリアージを行い、
CRITICAL/HIGH のみ Chatwork へ通知し、全件 S3 に保存する。
"""

import json
import logging
import os

from bedrock_client import BedrockClient
from chatwork_notifier import ChatworkNotifier
from dedup_checker import DedupChecker
from report_saver import ReportSaver

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event: dict, context) -> dict:
    """
    EventBridge から Security Hub Findings を受け取り、トリアージを行う。

    Args:
        event: EventBridge イベント（Security Hub Findings フォーマット）
        context: Lambda コンテキスト

    Returns:
        dict: 処理結果サマリ（processed, skipped, notified 件数）
    """
    findings = event.get("detail", {}).get("findings", [])
    if not findings:
        logger.info("処理対象の Findings がありません")
        return {"processed": 0, "skipped": 0, "notified": 0}

    bedrock = BedrockClient()
    notifier = ChatworkNotifier()
    dedup = DedupChecker()
    saver = ReportSaver()

    processed = 0
    skipped = 0
    notified = 0

    for finding in findings:
        finding_id = finding.get("Id", "")

        # iam: dynamodb:GetItem
        # 過去処理済みの Finding はスキップ（重複排除 TTL: 7日）
        if dedup.is_processed(finding_id):
            logger.info("スキップ（処理済み）: %s", finding_id)
            skipped += 1
            continue

        # Finding から必要フィールドを抽出
        title = finding.get("Title", "不明")
        severity_label = finding.get("Severity", {}).get("Label", "INFORMATIONAL")
        resources = finding.get("Resources", [{}])
        resource_type = resources[0].get("Type", "不明") if resources else "不明"
        resource_id = resources[0].get("Id", "不明") if resources else "不明"
        description = finding.get("Description", "")
        region = finding.get("Region", os.environ.get("AWS_REGION", "ap-northeast-1"))

        logger.info(
            "トリアージ開始: finding_id=%s title=%s severity=%s",
            finding_id, title, severity_label
        )

        # Bedrock で AI トリアージ実行
        triage_result = bedrock.triage(
            finding_title=title,
            severity=severity_label,
            resource_type=resource_type,
            resource_id=resource_id,
            description=description,
            region=region,
        )

        verdict = triage_result.get("verdict", "監視継続")
        risk_score = triage_result.get("risk_score", 5)

        # CRITICAL または HIGH の場合のみ Chatwork 通知
        if severity_label in ("CRITICAL", "HIGH"):
            success = notifier.notify(
                title=title,
                severity=severity_label,
                resource_id=resource_id,
                triage_result=triage_result,
            )
            if success:
                notified += 1

        # iam: s3:PutObject
        # フルレポートを S3 に保存
        saver.save(finding=finding, triage_result=triage_result)

        # iam: dynamodb:PutItem
        # 処理済みとして DynamoDB に記録（TTL: 7日）
        dedup.mark_processed(
            finding_id=finding_id,
            verdict=verdict,
            risk_score=risk_score,
        )

        processed += 1

    logger.info(
        "処理完了: processed=%d skipped=%d notified=%d",
        processed, skipped, notified
    )

    return {
        "processed": processed,
        "skipped": skipped,
        "notified": notified,
    }
