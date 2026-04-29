import json
import uuid
import urllib.request
import urllib.parse
import boto3
from datetime import datetime, timedelta, timezone
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="bmao/remediation")

dynamodb = boto3.resource("dynamodb")
ssm_client = boto3.client("ssm")

APPROVAL_TABLE = "bmao-approval-requests"
EXECUTION_TABLE = "bmao-execution-history"


def _get_ssm_param(name: str) -> str:
    response = ssm_client.get_parameter(Name=name, WithDecryption=True)
    return response["Parameter"]["Value"]


def _send_chatwork(message: str) -> None:
    try:
        room_id = _get_ssm_param("/bmao/chatwork/room_id")
        api_token = _get_ssm_param("/bmao/chatwork/api_token")
        url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
        body = urllib.parse.urlencode({"body": message}).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers={"X-ChatWorkToken": api_token, "Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            logger.info(f"Chatwork通知送信完了: status={resp.status}")
    except Exception as e:
        logger.error(f"Chatwork通知失敗: {e}")


# 破壊的操作の前に必ず人間承認を要求する安全設計の中核機能
@tracer.capture_method
def create_approval_request(params: dict) -> dict:
    action_type = params.get("action_type", "")
    resource_id = params.get("resource_id", "")
    description = params.get("description", "")
    risk_level = params.get("risk_level", "medium")

    request_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    ttl = int((now + timedelta(hours=24)).timestamp())

    table = dynamodb.Table(APPROVAL_TABLE)
    table.put_item(
        Item={
            "request_id": request_id,
            "action_type": action_type,
            "resource_id": resource_id,
            "description": description,
            "risk_level": risk_level,
            "status": "pending_approval",
            "created_at": now.isoformat(),
            "ttl": ttl,
        }
    )

    message = (
        f"[承認リクエスト] bmao-ops-autopilot\n"
        f"request_id: {request_id}\n"
        f"操作種別: {action_type}\n"
        f"対象リソース: {resource_id}\n"
        f"説明: {description}\n"
        f"リスクレベル: {risk_level}\n"
        f"有効期限: 24時間\n"
        f"承認する場合はDynamoDB bmao-approval-requestsのstatusを'approved'に更新してください。"
    )
    _send_chatwork(message)

    metrics.add_metric(name="ApprovalRequestsCreated", unit=MetricUnit.Count, value=1)
    logger.info(f"承認リクエスト作成: {request_id}")
    return {"request_id": request_id, "status": "pending_approval"}


@tracer.capture_method
def check_approval_status(params: dict) -> dict:
    request_id = params.get("request_id", "")

    table = dynamodb.Table(APPROVAL_TABLE)
    response = table.get_item(Key={"request_id": request_id})
    item = response.get("Item")

    if not item:
        return {"request_id": request_id, "status": "not_found"}

    now = datetime.now(timezone.utc)
    ttl = item.get("ttl", 0)
    if ttl and int(now.timestamp()) > ttl:
        return {"request_id": request_id, "status": "expired"}

    result = {
        "request_id": request_id,
        "status": item.get("status", "pending_approval"),
    }
    if item.get("approved_by"):
        result["approved_by"] = item["approved_by"]

    return result


# 承認済みリクエストのみSSMコマンド実行。request_idで承認状態を二重確認
@tracer.capture_method
def execute_ssm_document(params: dict) -> dict:
    instance_id = params.get("instance_id", "")
    document_name = params.get("document_name", "")
    parameters = params.get("parameters", {})
    request_id = params.get("request_id", "")

    approval = check_approval_status({"request_id": request_id})
    if approval.get("status") != "approved":
        logger.warning(f"未承認のSSMコマンド実行を拒否: request_id={request_id}, status={approval.get('status')}")
        return {
            "error": f"承認されていないリクエストです (status: {approval.get('status')})",
            "request_id": request_id,
        }

    ssm_params = {k: [v] if isinstance(v, str) else v for k, v in parameters.items()}

    response = ssm_client.send_command(
        InstanceIds=[instance_id],
        DocumentName=document_name,
        Parameters=ssm_params,
    )
    command = response["Command"]
    command_id = command["CommandId"]

    execution_table = dynamodb.Table(EXECUTION_TABLE)
    execution_table.put_item(
        Item={
            "execution_id": command_id,
            "request_id": request_id,
            "instance_id": instance_id,
            "document_name": document_name,
            "status": "sent",
            "executed_at": datetime.now(timezone.utc).isoformat(),
        }
    )

    metrics.add_metric(name="SSMCommandsExecuted", unit=MetricUnit.Count, value=1)
    logger.info(f"SSMコマンド実行: command_id={command_id}, instance_id={instance_id}")
    return {"command_id": command_id, "status": "sent"}


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics
def lambda_handler(event: dict, context) -> dict:
    logger.info("修復Agent Action Group呼び出し", extra={"event": event})

    function_name = event.get("function", "")
    parameters = {p["name"]: p["value"] for p in event.get("parameters", [])}

    dispatch = {
        "create_approval_request": create_approval_request,
        "check_approval_status": check_approval_status,
        "execute_ssm_document": execute_ssm_document,
    }

    if function_name not in dispatch:
        result = {"error": f"不明な関数: {function_name}"}
    else:
        result = dispatch[function_name](parameters)

    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": event.get("actionGroup", ""),
            "function": function_name,
            "functionResponse": {
                "responseBody": {
                    "TEXT": {
                        "body": json.dumps(result, ensure_ascii=False, default=str)
                    }
                }
            },
        },
    }
