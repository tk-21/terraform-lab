"""
WAF ブロック数閾値超過 → Chatwork 通知 Lambda

CloudWatch Alarm が ALARM 状態に遷移すると EventBridge 経由で起動される。
Chatwork REST API へ構造化メッセージを送信する。
"""
import os
import urllib.parse
import urllib.request

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()

# SSM パス・Chatwork Room ID は環境変数で注入（Terraform が設定）
CHATWORK_TOKEN_PARAM = os.environ["CHATWORK_TOKEN_PARAM"]
CHATWORK_ROOM_ID = os.environ["CHATWORK_ROOM_ID"]


def _get_ssm_parameter(name: str) -> str:
    # Chatwork トークンは ap-northeast-1 の SSM に保存
    # alert Lambda は us-east-1 にあるがクロスリージョン呼び出しで取得
    ssm = boto3.client("ssm", region_name="ap-northeast-1")
    response = ssm.get_parameter(Name=name, WithDecryption=True)
    return response["Parameter"]["Value"]


@tracer.capture_lambda_handler
@logger.inject_lambda_context
def handler(event: dict, context: LambdaContext) -> dict:
    logger.info("WAF alarm triggered", extra={"event": event})

    alarm_name = event["detail"]["alarmName"]
    state = event["detail"]["state"]["value"]
    reason = event["detail"]["state"]["reason"]
    region = event["region"]

    token = _get_ssm_parameter(CHATWORK_TOKEN_PARAM)

    message = (
        f"[info][title]⚠️ WAF 攻撃検知アラート[/title]"
        f"アラーム名: {alarm_name}\n"
        f"状態: {state}\n"
        f"理由: {reason}\n"
        f"リージョン: {region}\n"
        f"コンソール: https://console.aws.amazon.com/wafv2/homev2/web-acls"
        f"[/info]"
    )

    url = f"https://api.chatwork.com/v2/rooms/{CHATWORK_ROOM_ID}/messages"
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

    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork notified", extra={"status": resp.status})

    return {"statusCode": 200}
