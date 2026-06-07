"""
Secrets Manager ローテーション完了を Chatwork に通知する Lambda
EventBridge (CloudTrail 経由) から呼び出される

設計ポイント:
- VPC 外で実行: Chatwork API（外部インターネット）への HTTPS 接続が必要
- NAT Gateway 禁止のため VPC 設定なし
- Chatwork トークンは SSM SecureString で管理
"""
import os
import urllib.parse
import urllib.request

import boto3
from aws_lambda_powertools import Logger

logger = Logger()
ssm = boto3.client("ssm")


def lambda_handler(event: dict, context) -> None:
    """EventBridge イベントを受信して Chatwork に通知"""
    logger.info("ローテーション完了通知受信", extra={"event": event})

    token_resp = ssm.get_parameter(
        Name=os.environ["CHATWORK_TOKEN_PARAM"],
        WithDecryption=True,
    )
    room_id_resp = ssm.get_parameter(Name=os.environ["CHATWORK_ROOM_ID_PARAM"])

    token = token_resp["Parameter"]["Value"]
    room_id = room_id_resp["Parameter"]["Value"]

    secret_id = event.get("detail", {}).get("requestParameters", {}).get("secretId", "不明")
    event_time = event.get("time", "不明")

    message = (
        f"[info][title]Secrets Manager ローテーション完了[/title]"
        f"シークレット: {secret_id}\n"
        f"完了時刻: {event_time}\n"
        f"プロジェクト: aurora-rds-proxy-lab[/info]"
    )

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
        logger.info("Chatwork 通知成功", extra={"status": resp.status})
