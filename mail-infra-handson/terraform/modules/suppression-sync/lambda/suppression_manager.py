"""
サプレッションリスト同期Lambda

DynamoDB（アプリレベルのサプレッションリスト）と
SESアカウントレベルのサプレッションリストを同期する。

EventBridgeスケジュールで毎日AM2時（JST）に実行される。

処理フロー:
1. DynamoDBから全サプレッションリストを取得（Scan）
2. SESのアカウントレベルサプレッションリストを取得（ListSuppressedDestinations）
3. DynamoDBにあってSESにないものをSESに追加（PutSuppressedDestination）
4. TTL切れのアドレスをDynamoDBから削除（DeleteItem）
5. 統計情報をCloudWatchへPush（PutMetricData）

boto3 SES APIの使用:
- ses_client.list_suppressed_destinations()
- ses_client.put_suppressed_destination()
- ses_client.delete_suppressed_destination()
"""

import os
import time
from datetime import datetime, timezone
from typing import Optional

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext
from botocore.exceptions import ClientError

logger = Logger(service="suppression-mgr")
tracer = Tracer(service="suppression-mgr")
metrics = Metrics(namespace="MailInfraHandson")

dynamodb = boto3.resource("dynamodb")
ses_client = boto3.client("sesv2")

SUPPRESSION_TABLE_NAME = os.environ["SUPPRESSION_TABLE_NAME"]

# DynamoDB reason → SES SuppressionListReason のマッピング
REASON_MAP = {
    "bounce": "BOUNCE",
    "complaint": "COMPLAINT",
}


def _get_dynamodb_suppression_list() -> list[dict]:
    """DynamoDBから全サプレッションリストを取得する"""
    table = dynamodb.Table(SUPPRESSION_TABLE_NAME)
    items = []
    current_time = int(time.time())

    scan_kwargs: dict = {}
    while True:
        response = table.scan(**scan_kwargs)
        for item in response.get("Items", []):
            # TTL切れのアイテムをフィルタリング（DynamoDBはTTL削除に遅延がある）
            expires_at = item.get("expires_at")
            if expires_at and int(expires_at) < current_time:
                continue
            items.append(item)

        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        scan_kwargs["ExclusiveStartKey"] = last_key

    logger.info("DynamoDBサプレッションリスト取得完了", count=len(items))
    return items


def _get_ses_suppression_list() -> set[str]:
    """SESアカウントレベルのサプレッションリストを取得してメールアドレスのセットを返す"""
    suppressed_emails: set[str] = set()

    paginator = ses_client.get_paginator("list_suppressed_destinations")
    for page in paginator.paginate():
        for dest in page.get("SuppressedDestinationSummaries", []):
            suppressed_emails.add(dest["EmailAddress"].lower())

    logger.info("SESサプレッションリスト取得完了", count=len(suppressed_emails))
    return suppressed_emails


def _add_to_ses_suppression(email: str, reason: str) -> bool:
    """DynamoDBにあってSESにないアドレスをSESサプレッションリストに追加する"""
    ses_reason = REASON_MAP.get(reason.lower(), "BOUNCE")
    try:
        ses_client.put_suppressed_destination(
            EmailAddress=email,
            Reason=ses_reason,
        )
        logger.info("SESサプレッションリストに追加", email=email, reason=ses_reason)
        return True
    except ClientError as e:
        logger.error("SES追加失敗", email=email, error=str(e))
        return False


def _delete_expired_from_dynamodb(table_name: str) -> int:
    """TTL切れのアイテムをDynamoDBから明示的に削除する（TTL自動削除の遅延補完）"""
    table = dynamodb.Table(table_name)
    current_time = int(time.time())
    deleted_count = 0

    # TTL切れアイテムを検索して削除
    # DynamoDBはTTL期限後最大48時間以内に削除するが、このLambdaで即時削除を補完する
    scan_kwargs: dict = {
        "FilterExpression": "expires_at < :now",
        "ExpressionAttributeValues": {":now": current_time},
    }
    while True:
        response = table.scan(**scan_kwargs)
        for item in response.get("Items", []):
            try:
                table.delete_item(
                    Key={"email": item["email"], "reason": item["reason"]}
                )
                deleted_count += 1
            except ClientError as e:
                logger.warning("DynamoDB削除失敗", item=item, error=str(e))

        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        scan_kwargs["ExclusiveStartKey"] = last_key

    logger.info("TTL切れアイテム削除完了", deleted_count=deleted_count)
    return deleted_count


@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
@metrics.log_metrics
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    """
    DynamoDB と SES のサプレッションリストを同期するエントリポイント。

    DynamoDB（アプリレベル）を正となるソースとして扱い、
    SES（アカウントレベル）に欠落しているエントリを追加する。
    """
    logger.info("サプレッションリスト同期開始", triggered_at=datetime.now(timezone.utc).isoformat())

    # DynamoDB の有効なサプレッションリストを取得
    dynamodb_items = _get_dynamodb_suppression_list()
    dynamodb_emails = {item["email"].lower() for item in dynamodb_items}

    # SES のサプレッションリストを取得
    ses_emails = _get_ses_suppression_list()

    # DynamoDBにあってSESにない → SESに追加
    missing_in_ses = [
        item for item in dynamodb_items
        if item["email"].lower() not in ses_emails
    ]
    added_count = 0
    for item in missing_in_ses:
        if _add_to_ses_suppression(item["email"], item.get("reason", "bounce")):
            added_count += 1

    # TTL切れアイテムをDynamoDBから削除
    deleted_count = _delete_expired_from_dynamodb(SUPPRESSION_TABLE_NAME)

    # CloudWatchへ統計情報をPush
    metrics.add_metric(name="SuppressionListDynamoDBCount", unit=MetricUnit.Count, value=len(dynamodb_items))
    metrics.add_metric(name="SuppressionListSESCount", unit=MetricUnit.Count, value=len(ses_emails))
    metrics.add_metric(name="SuppressionSyncAdded", unit=MetricUnit.Count, value=added_count)
    metrics.add_metric(name="SuppressionExpiredDeleted", unit=MetricUnit.Count, value=deleted_count)

    result = {
        "status": "success",
        "dynamodb_count": len(dynamodb_items),
        "ses_count": len(ses_emails),
        "added_to_ses": added_count,
        "deleted_expired": deleted_count,
        "executed_at": datetime.now(timezone.utc).isoformat(),
    }

    logger.info("サプレッションリスト同期完了", **result)
    return result
