"""
時間コスト監視 Lambda:
CloudWatch Alarm → SNS → このLambda → Chatwork通知

推論コストが閾値を超えた場合にエンジニアへ即座に通知し、
Bedrockへの自動フォールバックが発動していることを周知する
"""
import json
import urllib.parse
import urllib.request

import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="cost-alert-lambda")
ssm = boto3.client("ssm", region_name="ap-northeast-1")


def _get_chatwork_credentials() -> tuple[str, str]:
    """SSM から Chatwork 認証情報を取得 (SecureString は復号して返す)"""
    token_param = ssm.get_parameter(Name="/chatwork/token", WithDecryption=True)
    room_param = ssm.get_parameter(Name="/chatwork/room-id")
    return token_param["Parameter"]["Value"], room_param["Parameter"]["Value"]


def _send_chatwork(message: str) -> None:
    """Chatwork REST API へ通知を送信する"""
    token, room_id = _get_chatwork_credentials()
    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({"body": message}).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork通知送信完了", status=resp.status)


@logger.inject_lambda_context
def handler(event: dict, context: LambdaContext) -> dict:
    """
    SNS 経由で渡される CloudWatch Alarm イベントを処理する

    event["Records"][0]["Sns"]["Message"] に CloudWatch Alarm の JSON が入る
    """
    for record in event.get("Records", []):
        sns_message = json.loads(record["Sns"]["Message"])
        alarm_name = sns_message.get("AlarmName", "unknown")
        state = sns_message.get("NewStateValue", "unknown")
        reason = sns_message.get("NewStateReason", "")

        message = (
            f"[info][title]🚨 AI推論コストアラート[/title]\n"
            f"アラーム: {alarm_name}\n"
            f"状態: {state}\n"
            f"理由: {reason}\n\n"
            f"時間あたりの推論コストが上限を超えました。\n"
            f"AI Gateway は自動的に Bedrock へのルーティングに切り替えています。\n"
            f"[/info]"
        )

        _send_chatwork(message)
        logger.info("コストアラート通知完了", alarm_name=alarm_name, state=state)

    return {"statusCode": 200}
