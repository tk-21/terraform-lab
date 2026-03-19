"""
Stream Processor Lambda

トリガー: DynamoDB Streams (jobs テーブル)
役割:
  ジョブステータスの変更イベントを検知し、テナント別・日次のメトリクスを集計する

学習ポイント:
  - DynamoDB Streams のイベント構造（INSERT / MODIFY / REMOVE）
  - NEW_AND_OLD_IMAGES で変更前後のデータを取得する方法
  - 冪等な集計処理（DynamoDB の atomic counter）
"""

import json
import os
import logging
from datetime import datetime, timezone, timedelta

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
METRICS_TABLE_NAME = os.environ["METRICS_TABLE_NAME"]
METRICS_RETENTION_DAYS = int(os.environ.get("METRICS_RETENTION_DAYS", "90"))

metrics_table = dynamodb.Table(METRICS_TABLE_NAME)


def parse_dynamodb_value(value: dict) -> str | int | None:
    """DynamoDB ストリームの型付き値を Python の値に変換する"""
    if "S" in value:
        return value["S"]
    if "N" in value:
        return int(value["N"])
    return None


def process_job_completed(new_image: dict) -> None:
    """
    ジョブが COMPLETED に変わったとき、テナント別・日次メトリクスを更新する。
    DynamoDB の ADD による atomic counter で冪等性を保つ。
    """
    tenant_id = parse_dynamodb_value(new_image.get("tenant_id", {}))
    completed_at = parse_dynamodb_value(new_image.get("completed_at", {}))
    input_tokens = parse_dynamodb_value(new_image.get("input_tokens", {})) or 0
    output_tokens = parse_dynamodb_value(new_image.get("output_tokens", {})) or 0
    model_used = parse_dynamodb_value(new_image.get("model_used", {})) or "unknown"

    if not tenant_id:
        return

    # completed_at がない場合は現在日付を使う
    if completed_at:
        date_str = completed_at[:10]  # "YYYY-MM-DD"
    else:
        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    expires_at = int(
        (datetime.now(timezone.utc) + timedelta(days=METRICS_RETENTION_DAYS)).timestamp()
    )

    # ADD で atomic に加算。アイテムがなければ自動作成される。
    metrics_table.update_item(
        Key={"tenant_id": tenant_id, "date": date_str},
        UpdateExpression=(
            "ADD completed_jobs :one, total_input_tokens :it, total_output_tokens :ot "
            "SET expires_at = :exp"
        ),
        ExpressionAttributeValues={
            ":one": 1,
            ":it": input_tokens,
            ":ot": output_tokens,
            ":exp": expires_at,
        },
    )
    logger.info(
        "Updated metrics for tenant=%s date=%s model=%s tokens=%d/%d",
        tenant_id, date_str, model_used, input_tokens, output_tokens,
    )


def process_job_failed(new_image: dict) -> None:
    """ジョブが FAILED に変わったとき、失敗カウンターを更新する"""
    tenant_id = parse_dynamodb_value(new_image.get("tenant_id", {}))
    if not tenant_id:
        return

    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    expires_at = int(
        (datetime.now(timezone.utc) + timedelta(days=METRICS_RETENTION_DAYS)).timestamp()
    )

    metrics_table.update_item(
        Key={"tenant_id": tenant_id, "date": date_str},
        UpdateExpression="ADD failed_jobs :one SET expires_at = :exp",
        ExpressionAttributeValues={":one": 1, ":exp": expires_at},
    )
    logger.info("Updated failure metrics for tenant=%s", tenant_id)


def handler(event, context):
    """
    DynamoDB Streams イベントを処理する。
    event["Records"] には変更レコードの配列が入っている。
    """
    for record in event.get("Records", []):
        event_name = record["eventName"]  # INSERT / MODIFY / REMOVE
        new_image = record.get("dynamodb", {}).get("NewImage", {})
        old_image = record.get("dynamodb", {}).get("OldImage", {})

        new_status = parse_dynamodb_value(new_image.get("status", {}))
        old_status = parse_dynamodb_value(old_image.get("status", {}))

        logger.info("Stream record: event=%s old_status=%s new_status=%s", event_name, old_status, new_status)

        # MODIFY かつ status が COMPLETED に変わったとき
        if event_name == "MODIFY" and new_status == "COMPLETED" and old_status != "COMPLETED":
            try:
                process_job_completed(new_image)
            except ClientError as e:
                logger.error("Failed to update completion metrics: %s", str(e))

        # MODIFY かつ status が FAILED に変わったとき
        elif event_name == "MODIFY" and new_status == "FAILED" and old_status != "FAILED":
            try:
                process_job_failed(new_image)
            except ClientError as e:
                logger.error("Failed to update failure metrics: %s", str(e))

    return {"processed": len(event.get("Records", []))}
