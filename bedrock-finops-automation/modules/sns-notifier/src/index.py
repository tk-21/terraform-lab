import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns_client = boto3.client("sns")
dynamodb = boto3.resource("dynamodb")

DYNAMODB_TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
PROJECT_NAME = os.environ["PROJECT_NAME"]


def handler(event: dict, context) -> dict:
    """
    Lambda エントリポイント。

    html-formatter Lambda の返り値を受け取り、SNS 経由で Email 通知する。
    html_report.presigned_url は html-formatter で生成済みのためそのまま利用する。
    """
    logger.info(f"Event: {json.dumps(event)}")

    report_id = event["report_id"]
    report_date = event["report_date"]
    presigned_url = event["html_report"]["presigned_url"]

    subject = build_subject(event)
    message = build_message(event, presigned_url)

    try:
        sns_client.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
        logger.info(f"SNS notification sent: report_id={report_id}")
        update_dynamodb_status(report_id, report_date, "notified")
    except ClientError as e:
        logger.error(f"Failed to publish SNS notification: {e}")
        update_dynamodb_status(report_id, report_date, "notify_failed")
        raise

    return {
        **event,
        "notification": {
            "sns_topic_arn": SNS_TOPIC_ARN,
            "sent_at": datetime.now(timezone.utc).isoformat(),
        },
    }


def build_subject(event: dict) -> str:
    report_date = event["report_date"]
    total_cost = event["current_month"]["total_cost"]
    return f"[{PROJECT_NAME}] Monthly Cost Report - {report_date} (${total_cost:.2f})"


def build_message(event: dict, presigned_url: str) -> str:
    report_date = event["report_date"]
    current_total = event["current_month"]["total_cost"]
    prev_total = event["prev_month"]["total_cost"]
    diff = current_total - prev_total
    diff_pct = (diff / prev_total * 100) if prev_total else 0.0

    anomalies = event.get("anomalies", [])
    ai_report = event.get("ai_report", {})

    lines = [
        f"■ 月次コストレポート - {report_date}",
        "",
        f"当月コスト: ${current_total:.2f}",
        f"前月コスト: ${prev_total:.2f}",
        f"増減: {'+' if diff >= 0 else ''}{diff:.2f} USD（{diff_pct:+.1f}%）",
        "",
    ]

    if anomalies:
        lines.append("■ 異常検知")
        for a in anomalies:
            lines.append(f"- [{a.get('severity')}] {a.get('description')}")
        lines.append("")

    if ai_report.get("summary"):
        lines.append("■ AI所見")
        lines.append(ai_report["summary"])
        lines.append("")

    lines.append("■ 詳細レポート（リンク有効期限: 7日間）")
    lines.append(presigned_url)

    return "\n".join(lines)


def update_dynamodb_status(report_id: str, report_date: str, status: str) -> None:
    table = dynamodb.Table(DYNAMODB_TABLE_NAME)
    table.update_item(
        Key={"report_id": report_id, "report_date": report_date},
        UpdateExpression="SET #s = :status, updated_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": status,
            ":ts": datetime.now(timezone.utc).isoformat(),
        },
    )
