"""
DLQ Handler Lambda (+ Cleanup Lambda として兼用)

2 つのトリガーで起動される:

[トリガー 1] EventBridge Rule
  - aws.states: Step Functions 実行の FAILED / TIMED_OUT イベント
  - Step Functions の Catch ブロックでは対処できなかった実行レベルの失敗を検知
  - DynamoDB のジョブステータスをセーフティネットとして FAILED に更新する

[トリガー 2] EventBridge Scheduled Rule (cron daily)
  - 1 時間以上 PENDING のままのジョブ（スタックジョブ）を検出して TIMEOUT に更新
  - SNS でアラートを送信する

学習ポイント:
  - EventBridge から Lambda へ渡されるイベント構造の違い
  - Step Functions 実行ステータスイベントの detail フィールド解析
  - DynamoDB の条件付き更新（ConditionExpression）で二重更新を防ぐ
"""

import json
import os
import logging
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
sns_client = boto3.client("sns")

JOBS_TABLE_NAME = os.environ["JOBS_TABLE_NAME"]
ALERT_TOPIC_ARN = os.environ["ALERT_TOPIC_ARN"]
STUCK_JOB_HOURS = int(os.environ.get("STUCK_JOB_HOURS", "1"))

jobs_table = dynamodb.Table(JOBS_TABLE_NAME)


def handle_sfn_failure(event: dict) -> None:
    """
    Step Functions 実行失敗イベントを処理する。
    detail.input から job_id を取得し、DynamoDB のステータスを更新する。
    """
    detail = event.get("detail", {})
    execution_arn = detail.get("executionArn", "unknown")
    status = detail.get("status", "UNKNOWN")
    cause = detail.get("cause", "Step Functions execution failed")
    error = detail.get("error", "UnknownError")

    # 実行入力の JSON から job_id を取得
    raw_input = detail.get("input", "{}")
    try:
        execution_input = json.loads(raw_input)
    except json.JSONDecodeError:
        logger.error("Could not parse execution input: %s", raw_input)
        return

    job_id = execution_input.get("job_id")
    if not job_id:
        logger.warning("No job_id in execution input: %s", execution_arn)
        return

    logger.info("SFN execution %s for job_id=%s status=%s", execution_arn, job_id, status)

    # 条件付き更新: すでに COMPLETED の場合は上書きしない
    try:
        jobs_table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET #s = :s, #e = :e",
            ConditionExpression="#s <> :completed",
            ExpressionAttributeNames={
                "#s": "status",
                "#e": "error_message",
            },
            ExpressionAttributeValues={
                ":s": "FAILED",
                ":e": f"[EventBridge] SFN execution failed: {error} - {cause}",
                ":completed": "COMPLETED",
            },
        )
        logger.info("Updated job %s to FAILED via EventBridge", job_id)
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.info("Job %s already COMPLETED, skipping update", job_id)
        else:
            raise


def handle_cleanup(event: dict) -> dict:
    """
    スケジュール実行: PENDING のまま STUCK_JOB_HOURS 以上経過したジョブを TIMEOUT に更新する。
    GSI status-created_at-index を使って効率的にスキャンする。
    """
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=STUCK_JOB_HOURS)).isoformat()
    logger.info("Checking for stuck PENDING jobs older than %s", cutoff)

    response = jobs_table.query(
        IndexName="status-created_at-index",
        KeyConditionExpression="(#s = :pending) AND created_at < :cutoff",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":pending": "PENDING", ":cutoff": cutoff},
    )

    stuck_jobs = response.get("Items", [])
    logger.info("Found %d stuck jobs", len(stuck_jobs))

    for job in stuck_jobs:
        job_id = job["job_id"]
        try:
            jobs_table.update_item(
                Key={"job_id": job_id},
                UpdateExpression="SET #s = :s, #e = :e",
                ConditionExpression="#s = :pending",
                ExpressionAttributeNames={"#s": "status", "#e": "error_message"},
                ExpressionAttributeValues={
                    ":s": "TIMEOUT",
                    ":e": f"Job stuck in PENDING for more than {STUCK_JOB_HOURS}h",
                    ":pending": "PENDING",
                },
            )
            logger.info("Marked job %s as TIMEOUT", job_id)
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                logger.error("Failed to update job %s: %s", job_id, str(e))

    if stuck_jobs:
        sns_client.publish(
            TopicArn=ALERT_TOPIC_ARN,
            Subject=f"[{JOBS_TABLE_NAME}] Stuck Jobs Detected",
            Message=(
                f"Found {len(stuck_jobs)} stuck PENDING jobs older than {STUCK_JOB_HOURS}h.\n"
                f"Job IDs: {[j['job_id'] for j in stuck_jobs]}"
            ),
        )

    return {"stuck_jobs_updated": len(stuck_jobs)}


def handler(event, context):
    """
    EventBridge から呼び出されるエントリーポイント。
    イベントの source と detail-type でルーティングする。
    """
    source = event.get("source", "")
    detail_type = event.get("detail-type", "")

    logger.info("Received event: source=%s detail-type=%s", source, detail_type)

    if source == "aws.states" and detail_type == "Step Functions Execution Status Change":
        handle_sfn_failure(event)

    elif source == "aws.events" or detail_type == "Scheduled Event":
        return handle_cleanup(event)

    else:
        logger.warning("Unhandled event: %s", json.dumps(event))
