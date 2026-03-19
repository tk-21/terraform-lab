"""
Dispatcher Lambda

トリガー: SQS (event source mapping)
役割:
  1. SQS メッセージをバリデーション
  2. DynamoDB に初期ジョブレコードを書き込む（status=PENDING）
  3. Step Functions 実行を開始する
  4. バッチ内で失敗したメッセージだけ SQS に戻す（部分バッチ失敗）

学習ポイント:
  - SQS event source mapping のバッチ処理パターン
  - 部分バッチ失敗（batchItemFailures）でメッセージ損失を防ぐ
  - Lambda から Step Functions を開始する基本パターン
"""

import json
import os
import logging
from datetime import datetime, timezone, timedelta

import boto3
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
sfn_client = boto3.client("stepfunctions")

JOBS_TABLE_NAME = os.environ["JOBS_TABLE_NAME"]
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
JOB_RETENTION_DAYS = int(os.environ.get("JOB_RETENTION_DAYS", "30"))

jobs_table = dynamodb.Table(JOBS_TABLE_NAME)


def validate_payload(body: dict) -> tuple[bool, str]:
    """必須フィールドのバリデーション"""
    required_fields = ["tenant_id", "prompt"]
    for field in required_fields:
        if not body.get(field):
            return False, f"Missing required field: {field}"

    complexity = body.get("complexity", "light")
    if complexity not in ("light", "complex"):
        return False, f"Invalid complexity: {complexity}. Must be 'light' or 'complex'"

    prompt = body["prompt"]
    if len(prompt) > 10000:
        return False, "prompt exceeds 10000 characters"

    return True, ""


def handler(event, context):
    """
    SQS バッチイベントを処理し、失敗したメッセージ ID を返す。
    batchItemFailures を使うことで成功分は削除、失敗分のみ再試行される。
    """
    batch_item_failures = []

    for record in event.get("Records", []):
        message_id = record["messageId"]

        try:
            body = json.loads(record["body"])
            logger.info("Processing message: %s, tenant: %s", message_id, body.get("tenant_id"))

            # バリデーション
            valid, error_msg = validate_payload(body)
            if not valid:
                logger.warning("Invalid payload for message %s: %s", message_id, error_msg)
                # バリデーションエラーはリトライしても無意味なので失敗扱いにしない
                # → DLQ には流さず、ここで破棄する（設計判断の学習ポイント）
                continue

            # SQS messageId を job_id として使用する
            # これにより POST /jobs レスポンスの messageId でジョブを追跡できる
            job_id = message_id
            tenant_id = body["tenant_id"]
            prompt = body["prompt"]
            complexity = body.get("complexity", "light")
            now = datetime.now(timezone.utc)
            expires_at = int((now + timedelta(days=JOB_RETENTION_DAYS)).timestamp())

            # DynamoDB にジョブレコードを書き込む（status=PENDING）
            jobs_table.put_item(
                Item={
                    "job_id": job_id,
                    "tenant_id": tenant_id,
                    "prompt": prompt,
                    "complexity": complexity,
                    "status": "PENDING",
                    "created_at": now.isoformat(),
                    "expires_at": expires_at,
                    "sqs_message_id": message_id,
                }
            )

            # Step Functions 実行を開始
            # execution name は一意である必要があるため job_id を使用
            sfn_client.start_execution(
                stateMachineArn=STATE_MACHINE_ARN,
                name=f"job-{job_id}",
                input=json.dumps({
                    "job_id": job_id,
                    "tenant_id": tenant_id,
                    "prompt": prompt,
                    "complexity": complexity,
                }),
            )

            logger.info("Started execution for job_id=%s, complexity=%s", job_id, complexity)

        except Exception as e:
            logger.error("Failed to process message %s: %s", message_id, str(e), exc_info=True)
            # 部分バッチ失敗: このメッセージだけ SQS に戻してリトライ
            batch_item_failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": batch_item_failures}
