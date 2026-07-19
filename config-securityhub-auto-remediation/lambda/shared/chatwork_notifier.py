"""
Chatwork通知モジュール
修復結果をChatwork REST APIで通知する。

設計意図:
  - SSMから毎回取得するのではなくキャッシュを使う (Lambda実行コンテキスト再利用)
  - urllib.requestを使い外部ライブラリ依存をなくす
  - 通知失敗は修復結果に影響させない (ベストエフォート)
"""
import os
import urllib.request
import urllib.parse
from typing import Optional

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="csar-chatwork-notifier")

REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

# SSMからの取得結果をキャッシュ (Lambda実行コンテキスト再利用のため)
_chatwork_token: Optional[str] = None
_chatwork_room_id: Optional[str] = None


def _get_chatwork_credentials() -> tuple[str, str]:
    """SSM Parameter StoreからChatwork認証情報を取得する (キャッシュあり)"""
    global _chatwork_token, _chatwork_room_id

    if _chatwork_token and _chatwork_room_id:
        return _chatwork_token, _chatwork_room_id

    ssm = boto3.client("ssm", region_name=REGION)
    # WithDecryption=True: SecureString型パラメータの復号に必要
    token_resp = ssm.get_parameter(Name="/csar/chatwork/token", WithDecryption=True)
    room_resp = ssm.get_parameter(Name="/csar/chatwork/room_id", WithDecryption=True)

    _chatwork_token = token_resp["Parameter"]["Value"]
    _chatwork_room_id = room_resp["Parameter"]["Value"]

    return _chatwork_token, _chatwork_room_id


def _build_message(
    resource_type: str,
    resource_id: str,
    rule_name: str,
    remediation_action: str,
    status: str,
    remediation_id: str,
    extra_info: Optional[str] = None,
) -> str:
    """Chatwork通知メッセージを構築する"""
    status_label = {
        "SUCCESS": "[修復成功]",
        "FAILED": "[修復失敗 / 要確認]",
        "MANUAL_REQUIRED": "[手動対応が必要]",
    }.get(status, f"[{status}]")

    lines = [
        status_label,
        f"リソース種別: {resource_type}",
        f"リソースID: {resource_id}",
        f"違反ルール: {rule_name}",
        f"修復内容: {remediation_action}",
        f"修復ID: {remediation_id}",
    ]
    if extra_info:
        lines.append(f"追加情報: {extra_info}")

    return "\n".join(lines)


def notify_remediation_result(
    resource_type: str,
    resource_id: str,
    rule_name: str,
    remediation_action: str,
    status: str,
    remediation_id: str,
    extra_info: Optional[str] = None,
) -> None:
    """修復結果をChatworkに通知する"""
    try:
        token, room_id = _get_chatwork_credentials()
    except Exception as e:
        # SSM取得失敗は通知をスキップ (修復結果には影響させない)
        logger.error("Chatwork認証情報取得失敗", extra={"error": str(e)})
        return

    message = _build_message(
        resource_type=resource_type,
        resource_id=resource_id,
        rule_name=rule_name,
        remediation_action=remediation_action,
        status=status,
        remediation_id=remediation_id,
        extra_info=extra_info,
    )

    try:
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
            logger.info("Chatwork通知成功", extra={"status_code": resp.status})
    except Exception as e:
        # 通知失敗はベストエフォート (修復済みなので致命的エラーにしない)
        logger.error("Chatwork通知エラー", extra={"error": str(e)})
