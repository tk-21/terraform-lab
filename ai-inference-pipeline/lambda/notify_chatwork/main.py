"""
Chatwork通知Lambda
Step Functionsのパイプライン完了・失敗時に呼び出される。
成功/失敗どちらのケースも同じLambdaで処理する。
"""
import os
import urllib.request
import urllib.parse
import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="notify-chatwork")

ssm = boto3.client("ssm")

ROOM_ID = os.environ["CHATWORK_ROOM_ID"]
SSM_TOKEN_PATH = os.environ["SSM_TOKEN_PATH"]


def get_chatwork_token() -> str:
    """SSM Parameter StoreからChatworkトークンを取得（SecureString）"""
    response = ssm.get_parameter(Name=SSM_TOKEN_PATH, WithDecryption=True)
    return response["Parameter"]["Value"]


def format_message(event: dict) -> str:
    """
    ジョブの結果に応じてChatworkメッセージを整形
    成功時は推論サマリーを、失敗時はエラー内容を含める
    """
    job_id = event.get("job_id", "unknown")
    status = event.get("status", "unknown")

    if status == "success":
        result = event.get("inference_result", {})
        summary = result.get("summary", "サマリーなし")
        themes = ", ".join(result.get("key_themes", []))
        quality = result.get("data_quality", "-")

        return (
            f"[info][title]✅ AI推論パイプライン完了[/title]"
            f"Job ID: {job_id}\n"
            f"データ品質: {quality}\n"
            f"サマリー: {summary}\n"
            f"主要テーマ: {themes}"
            f"[/info]"
        )
    else:
        error = event.get("error", "不明なエラー")
        return (
            f"[info][title]❌ AI推論パイプライン失敗[/title]"
            f"Job ID: {job_id}\n"
            f"エラー: {error}"
            f"[/info]"
        )


def send_chatwork_message(token: str, room_id: str, message: str) -> None:
    """Chatwork APIにPOSTリクエストを送信"""
    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({"body": message}).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=10) as resp:
        logger.info("Chatwork送信完了", status_code=resp.status)


@logger.inject_lambda_context
def handler(event: dict, context: LambdaContext) -> dict:
    logger.info("通知Lambda開始", event=event)

    token = get_chatwork_token()
    message = format_message(event)
    send_chatwork_message(token, ROOM_ID, message)

    return {"status": "notified"}
