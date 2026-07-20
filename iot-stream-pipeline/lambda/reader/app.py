"""
API Gateway → DynamoDB 読み取りLambda

設計方針:
- device_idによる最新データ取得と、時系列範囲クエリの2パターンをサポートする
- Lambda Proxy統合を前提とし、API Gatewayがそのままレスポンスを返す形式にする
- Decimalはfloatに変換してJSONシリアライズエラーを防ぐ
"""

import json
import os
from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger
from boto3.dynamodb.conditions import Key
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="iot-reader")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE_NAME"])


def decimal_to_float(obj):
    """DynamoDBのDecimal型をJSONシリアライズ可能なfloatに変換する"""
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError(f"シリアライズ不可能な型: {type(obj)}")


@logger.inject_lambda_context(log_event=True)
def handler(event: dict, context: LambdaContext) -> dict:
    path_params = event.get("pathParameters") or {}
    query_params = event.get("queryStringParameters") or {}

    device_id = path_params.get("device_id")
    if not device_id:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "device_idは必須パラメータです"}),
        }

    limit = int(query_params.get("limit", 10))

    try:
        # ScanIndexForward=Falseで最新データを先頭に取得する
        # 理由: センサー監視では最新の状態を最優先で確認するユースケースが多い
        response = table.query(
            KeyConditionExpression=Key("device_id").eq(device_id),
            ScanIndexForward=False,
            Limit=limit,
        )
        items = response.get("Items", [])
        logger.info(f"取得件数: {len(items)}, device_id={device_id}")

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
            },
            "body": json.dumps(
                {"device_id": device_id, "count": len(items), "items": items},
                default=decimal_to_float,
                ensure_ascii=False,
            ),
        }

    except Exception as e:
        logger.error(f"DynamoDBクエリ失敗: {e}", exc_info=True)
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "データ取得に失敗しました"}),
        }
