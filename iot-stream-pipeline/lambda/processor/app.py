"""
Kinesis → DynamoDB ストリーム処理Lambda

設計方針:
- base64デコード後にJSONパースする (Kinesisはbase64エンコードしてデータを渡す)
- TTLは受信時刻+72時間で設定する (ハンズオンデータの自動クリーンアップ)
- バッチ内の1件でも失敗した場合はbisect_on_function_error=trueで部分リトライする
"""

import base64
import json
import os
import time
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="iot-processor")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE_NAME"])

TTL_SECONDS = 72 * 60 * 60  # 72時間後に自動削除


@logger.inject_lambda_context(log_event=False)
def handler(event: dict, context: LambdaContext) -> dict:
    records = event.get("Records", [])
    logger.info(f"受信レコード数: {len(records)}")

    failed_items = []

    for record in records:
        try:
            # KinesisはデータをBase64エンコードして渡すため、デコードが必須
            raw_data = base64.b64decode(record["kinesis"]["data"]).decode("utf-8")
            sensor_data = json.loads(raw_data)

            device_id = sensor_data["device_id"]
            timestamp = sensor_data.get("timestamp", datetime.now(timezone.utc).isoformat())

            item = {
                "device_id": device_id,
                "timestamp": timestamp,
                # boto3はfloatを直接受け付けないため、str経由でDecimalに変換する
                "temperature": Decimal(str(sensor_data.get("temperature", 0))),
                "humidity": Decimal(str(sensor_data.get("humidity", 0))),
                "status": sensor_data.get("status", "unknown"),
                # TTLはUnixタイムスタンプ(秒)で指定する必要がある
                "expires_at": int(time.time()) + TTL_SECONDS,
            }

            table.put_item(Item=item)
            logger.info(f"書き込み成功: device_id={device_id}, timestamp={timestamp}")

        except Exception as e:
            logger.error(f"レコード処理失敗: {e}", exc_info=True)
            # 失敗したシーケンス番号を返すことで部分的なリトライが可能になる
            failed_items.append(
                {"itemIdentifier": record["kinesis"]["sequenceNumber"]}
            )

    # 失敗したアイテムのみKinesisに返す (bisectOnFunctionError と組み合わせる)
    return {"batchItemFailures": failed_items}
