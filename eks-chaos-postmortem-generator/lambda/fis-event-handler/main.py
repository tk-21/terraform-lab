"""
FIS Orchestrator Lambda - fis-event-handler
EventBridgeからFIS実験完了イベントを受信し、
DynamoDB冪等性チェック後にStep Functionsワークフローを起動する。

設計意図:
- FIS実験のcompleted/failed/stopped 全状態をStep Functionsに渡す（失敗分析のため）
- DynamoDB ConditionExpression で同一実験IDの重複処理を防止
- Step Functions ARN未設定時（Phase 2単独デプロイ）はスキップしてログのみ出力
"""

import json
import os
import time
from datetime import datetime, timezone

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext
from botocore.exceptions import ClientError

logger = Logger()
tracer = Tracer()

dynamodb = boto3.resource("dynamodb")
sfn_client = boto3.client("stepfunctions")

TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
STEP_FUNCTIONS_ARN = os.environ.get("STEP_FUNCTIONS_ARN", "")


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    """FISイベントを受信してStep Functionsポストモーテムワークフローを起動する"""

    logger.info("FISイベント受信", raw_event=event)

    # EventBridgeイベントのdetailからFIS実験情報を抽出
    detail = event.get("detail", {})
    experiment_id = detail.get("id", "")
    state_info = detail.get("state", {})
    state = state_info.get("status", "unknown")
    experiment_template_id = detail.get("experimentTemplateId", "")

    if not experiment_id:
        logger.error("experiment_idが取得できません", detail=detail)
        return {"statusCode": 400, "body": "missing_experiment_id"}

    # 開始・終了時刻をISO 8601形式で取得
    start_time = detail.get("startTime", datetime.now(timezone.utc).isoformat())
    end_time = detail.get("endTime", datetime.now(timezone.utc).isoformat())

    # テンプレートIDから実験種別を推定（ポストモーテムの分類に使用）
    experiment_type = _extract_experiment_type(experiment_template_id)

    logger.info(
        "FIS実験情報抽出完了",
        experiment_id=experiment_id,
        experiment_type=experiment_type,
        state=state,
        experiment_template_id=experiment_template_id,
    )

    # DynamoDB冪等性チェック: 同一実験IDの重複処理を防ぐ
    if not _put_idempotency_record(experiment_id, state):
        logger.warning("重複処理をスキップします", experiment_id=experiment_id)
        return {"statusCode": 200, "body": "duplicate_skipped"}

    # Step Functions入力を構築してワークフローを起動
    sfn_input = {
        "experiment_id": experiment_id,
        "experiment_type": experiment_type,
        "start_time": str(start_time),
        "end_time": str(end_time),
        "state": state,
    }

    _start_step_functions(experiment_id, sfn_input)

    logger.info(
        "処理完了",
        experiment_id=experiment_id,
        experiment_type=experiment_type,
    )
    return {"statusCode": 200, "body": "workflow_started"}


def _extract_experiment_type(template_id: str) -> str:
    """FIS実験テンプレートIDから実験種別を推定する"""
    type_keywords = {
        "pod-kill": "pod-kill",
        "node-termination": "node-termination",
        "network-latency": "network-latency",
        "cpu-stress": "cpu-stress",
    }
    for keyword, experiment_type in type_keywords.items():
        if keyword in template_id:
            return experiment_type
    return "unknown"


def _put_idempotency_record(experiment_id: str, state: str) -> bool:
    """
    DynamoDBに実験処理レコードを書き込む。
    ConditionExpression で experiment_id が存在しない場合のみ成功し、
    既存レコードがある場合は ConditionalCheckFailedException で失敗する。
    """
    table = dynamodb.Table(TABLE_NAME)
    # TTL: 現在時刻 + 7日間（Unix時間）
    ttl = int(time.time()) + (7 * 24 * 60 * 60)

    try:
        table.put_item(
            Item={
                "experiment_id": experiment_id,
                "state": state,
                "processed_at": datetime.now(timezone.utc).isoformat(),
                "ttl": ttl,
            },
            # 冪等性保証: experiment_idが存在しない場合のみ書き込みを許可
            ConditionExpression="attribute_not_exists(experiment_id)",
        )
        logger.info("冪等性レコード書き込み成功", experiment_id=experiment_id)
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # 既に処理済みの実験ID - 重複処理をスキップ
            return False
        logger.error(
            "DynamoDB書き込みエラー",
            experiment_id=experiment_id,
            error=str(e),
        )
        raise


def _start_step_functions(experiment_id: str, sfn_input: dict) -> None:
    """
    Step Functionsポストモーテムワークフローを起動する。
    STEP_FUNCTIONS_ARN が未設定の場合はスキップ（Phase 2単独デプロイ対応）。
    """
    if not STEP_FUNCTIONS_ARN:
        logger.warning(
            "STEP_FUNCTIONS_ARNが未設定のためStep Functions起動をスキップ（Phase 3で設定してください）",
            experiment_id=experiment_id,
        )
        return

    # 実行名: postmortem-{experiment_id}-{timestamp}（64文字上限内に収める）
    execution_name = f"postmortem-{experiment_id[:20]}-{int(time.time())}"

    response = sfn_client.start_execution(
        stateMachineArn=STEP_FUNCTIONS_ARN,
        name=execution_name,
        input=json.dumps(sfn_input),
    )

    logger.info(
        "Step Functions起動完了",
        execution_arn=response["executionArn"],
        experiment_id=experiment_id,
    )
