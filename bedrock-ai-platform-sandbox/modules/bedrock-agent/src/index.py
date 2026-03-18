"""
Bedrock Agent Action Handler (infra-ops)

Bedrock Agent Action Group からのリクエストを処理する。
Action Group: infra-ops
  - GET  /infrastructure/status   : インフラ稼働状況確認
  - GET  /costs/summary           : 月次コスト概算取得
  - POST /alerts/acknowledge      : アラート確認済み登録
"""

import json
import os
from datetime import datetime, timezone

import boto3

# ----------------------------------------------------------------
# 環境変数（Terraform で設定）
# ----------------------------------------------------------------
USAGE_TABLE = os.environ.get("USAGE_TABLE", "")

# ----------------------------------------------------------------
# AWS クライアント（USAGE_TABLE が設定されている場合のみ初期化）
# ----------------------------------------------------------------
_dynamodb = boto3.resource("dynamodb") if USAGE_TABLE else None


# ================================================================
# ハンドラ
# ================================================================
def lambda_handler(event: dict, context) -> dict:
    """
    Bedrock Agent からの Action Group 呼び出しを受け取り、適切なアクションを実行する。

    event 構造:
    {
      "messageVersion": "1.0",
      "agent":          { "name": "...", "id": "...", "aliasId": "..." },
      "actionGroup":    "infra-ops",
      "apiPath":        "/infrastructure/status",
      "httpMethod":     "GET",
      "parameters":     [],
      "requestBody":    {}
    }
    """
    action_group = event.get("actionGroup", "")
    api_path     = event.get("apiPath", "")
    http_method  = event.get("httpMethod", "GET").upper()
    request_body = event.get("requestBody", {})

    print(f"[INFO] Action group={action_group} path={api_path} method={http_method}")

    if api_path == "/infrastructure/status":
        status, body = 200, _get_infrastructure_status()
    elif api_path == "/costs/summary":
        status, body = 200, _get_costs_summary()
    elif api_path == "/alerts/acknowledge" and http_method == "POST":
        status, body = 200, _acknowledge_alert(request_body)
    else:
        status, body = 404, {"error": f"Unknown path: {api_path}"}

    return _build_response(action_group, api_path, http_method, status, body)


# ================================================================
# Action ハンドラ
# ================================================================
def _get_infrastructure_status() -> dict:
    return {
        "status":    "healthy",
        "timestamp": _now(),
        "services": {
            "bedrock_runtime":   "operational",
            "knowledge_base":    "operational",
            "aurora_pgvector":   "operational",
            "api_gateway":       "operational",
            "cost_controller":   "operational",
        },
    }


def _get_costs_summary() -> dict:
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    breakdown = {
        "vpc_endpoints":     14.0,
        "nat_gateway":        4.5,
        "aurora_serverless":  5.0,
        "bedrock_api":        5.0,
        "other":              1.5,
    }
    result: dict = {
        "month":           month,
        "currency":        "USD",
        "total_estimated": sum(breakdown.values()),
        "breakdown":       breakdown,
    }

    # DynamoDB から実際のトークン使用量を集計（オプション）
    if USAGE_TABLE and _dynamodb:
        try:
            tbl    = _dynamodb.Table(USAGE_TABLE)
            prefix = datetime.now(timezone.utc).strftime("%Y%m")
            resp   = tbl.scan(
                FilterExpression="begins_with(#d, :p)",
                ExpressionAttributeNames={"#d": "date"},
                ExpressionAttributeValues={":p": prefix},
            )
            total = sum(int(item.get("total_tokens", 0)) for item in resp.get("Items", []))
            result["total_tokens_this_month"] = total
        except Exception as e:
            print(f"[WARN] Failed to aggregate token usage: {e}")

    return result


def _acknowledge_alert(request_body: dict) -> dict:
    # Bedrock Agent は requestBody.content.application/json.properties 形式でデータを渡す
    content  = request_body.get("content", {})
    app_json = content.get("application/json", {})
    props    = {p["name"]: p["value"] for p in app_json.get("properties", [])}

    alert_id = props.get("alert_id", "unknown")
    reason   = props.get("reason", "")

    print(f"[INFO] Alert acknowledged: id={alert_id} reason={reason}")
    return {
        "status":    "acknowledged",
        "alert_id":  alert_id,
        "timestamp": _now(),
    }


# ================================================================
# Bedrock Agent レスポンスフォーマット
# ================================================================
def _build_response(
    action_group: str,
    api_path: str,
    http_method: str,
    status: int,
    body: dict,
) -> dict:
    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup":    action_group,
            "apiPath":        api_path,
            "httpMethod":     http_method,
            "httpStatusCode": status,
            "responseBody": {
                "application/json": {
                    "body": json.dumps(body, ensure_ascii=False)
                }
            },
        },
    }


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
