"""
Chatwork 通知 Lambda

概要:
    html-formatter の出力を受け取り、月次コストレポートの要約を Chatwork に送信する。

    機密情報の取得:
        - Chatwork API トークン: Secrets Manager
        - Chatwork ルーム ID:    SSM Parameter Store

    通知内容:
        - コスト概要（当月・前月比）
        - 異常検知サマリー
        - AI 所見（1行）
        - HTML レポートの署名付き URL（7日間有効）
"""

import json
import logging
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REPORT_BUCKET_NAME = os.environ["REPORT_BUCKET_NAME"]
DYNAMODB_TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "bedrock-finops-automation")
CHATWORK_API_TOKEN_SECRET_NAME = os.environ["CHATWORK_API_TOKEN_SECRET_NAME"]
CHATWORK_ROOM_ID_PARAMETER_NAME = os.environ["CHATWORK_ROOM_ID_PARAMETER_NAME"]

CHATWORK_API_BASE = "https://api.chatwork.com/v2"


# ============================================================
# 機密情報取得（Secrets Manager / SSM）
# ============================================================

def get_chatwork_api_token() -> str:
    """
    Secrets Manager から Chatwork API トークンを取得する。

    シークレット形式: {"api_token": "xxxxxxxxxxxxxxxx"}
    """
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=CHATWORK_API_TOKEN_SECRET_NAME)
    secret = json.loads(response["SecretString"])
    return secret["api_token"]


def get_chatwork_room_id() -> str:
    """
    SSM Parameter Store から Chatwork ルーム ID を取得する。

    ルーム ID は機密性が低いため SSM Parameter Store（SecureString ではなく String）で管理。
    コスト節約のため Secrets Manager（$0.40/月）ではなく SSM（無料）を使用。
    """
    client = boto3.client("ssm")
    response = client.get_parameter(Name=CHATWORK_ROOM_ID_PARAMETER_NAME)
    return response["Parameter"]["Value"]


# ============================================================
# Chatwork メッセージ構築
# ============================================================

SEVERITY_EMOJI = {
    "HIGH":   "[要対応]",
    "MEDIUM": "[注意]",
    "LOW":    "[情報]",
}


def build_message(event: dict) -> str:
    """
    Chatwork 通知メッセージを組み立てる。

    Chatwork 記法:
        [info][title]...[/title]...[/info] で囲むと見やすいボックスになる。
        [code] でコードブロック表示。
    """
    report_date = event["report_date"]
    current = event["current_month"]
    prev = event["prev_month"]
    anomalies = event.get("anomalies", [])
    ai_report = event.get("ai_report", {})
    html_report = event.get("html_report", {})

    current_total = current["total_cost"]
    prev_total = prev["total_cost"]

    # 前月比
    if prev_total > 0.01:
        change_pct = ((current_total - prev_total) / prev_total) * 100
        change_str = f"{change_pct:+.1f}%"
        trend = "上昇" if change_pct > 0 else "低下"
    else:
        change_str = "N/A"
        trend = "-"

    # 異常検知サマリー
    if anomalies:
        high_count = sum(1 for a in anomalies if a.get("severity") == "HIGH")
        medium_count = sum(1 for a in anomalies if a.get("severity") == "MEDIUM")
        anomaly_lines = []
        if high_count:
            anomaly_lines.append(f"  [要対応] HIGH: {high_count}件")
        if medium_count:
            anomaly_lines.append(f"  [注意] MEDIUM: {medium_count}件")
        low_count = len(anomalies) - high_count - medium_count
        if low_count:
            anomaly_lines.append(f"  [情報] LOW: {low_count}件")
        anomaly_summary = "\n".join(anomaly_lines)

        # 個別の異常詳細（HIGH のみ本文に展開）
        high_details = ""
        for a in anomalies:
            if a.get("severity") == "HIGH":
                high_details += f"\n  ■ {a.get('description', '')}"
    else:
        anomaly_summary = "  異常なし"
        high_details = ""

    # AI 所見（summary の最初の1文のみ抜粋）
    ai_summary = ai_report.get("summary", "")
    if ai_summary and len(ai_summary) > 100:
        ai_summary = ai_summary[:97] + "..."

    risk_level = ai_report.get("risk_level", "UNKNOWN")

    # レポート URL
    report_url = html_report.get("presigned_url", "")
    url_section = f"\n[info][title]詳細レポート（7日間有効）[/title]{report_url}[/info]" if report_url else ""

    message = f"""[info][title]AWS FinOps 月次コストレポート {report_date}[/title]
■ コスト概要
  当月合計: ${current_total:.2f}
  前月合計: ${prev_total:.2f}
  前月比:   {change_str}（{trend}）

■ 異常検知（{len(anomalies)}件）
{anomaly_summary}{high_details}

■ AI 所見（リスクレベル: {risk_level}）
  {ai_summary}
[/info]{url_section}"""

    return message.strip()


# ============================================================
# Chatwork API 送信
# ============================================================

def send_chatwork_message(api_token: str, room_id: str, message: str) -> dict:
    """
    Chatwork API v2 でメッセージを送信する。

    標準ライブラリの urllib を使用（requests 等の外部依存なし）。

    API リファレンス: POST /rooms/{room_id}/messages
    """
    url = f"{CHATWORK_API_BASE}/rooms/{room_id}/messages"
    headers = {
        "X-ChatWorkToken": api_token,
        "Content-Type": "application/x-www-form-urlencoded",
    }

    # urllib では body をバイト列に encode して渡す
    body = urllib.parse.urlencode({"body": message, "self_unread": "0"}).encode("utf-8")

    # urllib.parse が urllib.request より先にインポートされていないため明示的に使用
    import urllib.parse  # noqa: PLC0415

    body = urllib.parse.urlencode({"body": message, "self_unread": "0"}).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            response_body = json.loads(resp.read().decode("utf-8"))
            logger.info(f"Chatwork message sent: message_id={response_body.get('message_id')}")
            return response_body
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        logger.error(f"Chatwork API error: status={e.code}, body={error_body}")
        raise


# ============================================================
# DynamoDB ステータス更新
# ============================================================

def update_dynamodb_final_status(
    report_id: str, report_date: str, message_id: str
) -> None:
    """全ステップ完了後の最終ステータスを DynamoDB に記録する。"""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE_NAME)

    table.update_item(
        Key={"report_id": report_id, "report_date": report_date},
        UpdateExpression=(
            "SET #s = :status, chatwork_message_id = :mid, completed_at = :ts"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": "completed",
            ":mid": message_id,
            ":ts": datetime.now(timezone.utc).isoformat(),
        },
    )


# ============================================================
# Lambda ハンドラ
# ============================================================

def handler(event: dict, context) -> dict:
    """
    Lambda エントリポイント。Step Functions の最終ステート。

    Args:
        event: html-formatter Lambda の返り値

    Returns:
        通知結果を含む最終サマリー dict
    """
    logger.info(f"Sending Chatwork notification for: {event.get('report_id')}")

    report_id = event["report_id"]
    report_date = event["report_date"]

    # ── 機密情報取得 ──────────────────────────────────────
    api_token = get_chatwork_api_token()
    room_id = get_chatwork_room_id()

    # ── メッセージ構築・送信 ──────────────────────────────
    message = build_message(event)
    logger.info(f"Message length: {len(message)} chars")

    result = send_chatwork_message(api_token, room_id, message)
    message_id = str(result.get("message_id", ""))

    # ── DynamoDB に完了記録 ───────────────────────────────
    update_dynamodb_final_status(report_id, report_date, message_id)

    logger.info(f"Workflow completed: report_id={report_id}, message_id={message_id}")

    return {
        "report_id": report_id,
        "report_date": report_date,
        "status": "completed",
        "chatwork_message_id": message_id,
        "html_s3_key": event.get("html_report", {}).get("s3_key", ""),
    }
