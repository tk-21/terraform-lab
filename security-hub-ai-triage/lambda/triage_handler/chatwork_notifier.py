"""
chatwork_notifier - Chatwork への通知送信モジュール

Secrets Manager から Chatwork トークンを取得し、
CRITICAL/HIGH の Security Hub Findings をフォーマットして通知する。
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
import urllib.request
import urllib.parse
import urllib.error

logger = logging.getLogger(__name__)

JST = timezone(timedelta(hours=9))
CHATWORK_API_BASE = "https://api.chatwork.com/v2"


class ChatworkNotifier:
    """Chatwork へセキュリティアラートを通知するクライアント。"""

    def __init__(self) -> None:
        """Secrets Manager クライアントと環境変数から設定を初期化する。"""
        # iam: secretsmanager:GetSecretValue
        self._secrets_client = boto3.client("secretsmanager")
        self._secret_arn = os.environ.get("CHATWORK_SECRET_ARN", "")
        self._room_id = os.environ.get("CHATWORK_ROOM_ID", "")
        self._token: str | None = None

    def _get_token(self) -> str:
        """
        Secrets Manager から Chatwork API トークンを取得する。

        トークンはインスタンス変数にキャッシュし、複数 Finding の処理でも
        1 回のみ API を呼び出す。

        Returns:
            str: Chatwork API トークン

        Raises:
            RuntimeError: トークンの取得に失敗した場合
        """
        if self._token:
            return self._token

        # iam: secretsmanager:GetSecretValue
        # Chatwork トークンを Secrets Manager から安全に取得（環境変数への直接保存は禁止）
        response = self._secrets_client.get_secret_value(SecretId=self._secret_arn)
        secret_string = response.get("SecretString", "")

        # シークレット値が JSON 形式の場合は "token" キーを参照
        try:
            secret_data = json.loads(secret_string)
            self._token = secret_data.get("token", secret_string)
        except json.JSONDecodeError:
            self._token = secret_string

        return self._token

    def notify(
        self,
        title: str,
        severity: str,
        resource_id: str,
        triage_result: dict,
    ) -> bool:
        """
        Security Hub Findings の Chatwork 通知を送信する。

        通知失敗は例外を raise せず、エラーログを出力して False を返す。

        Args:
            title: Finding のタイトル
            severity: 重大度ラベル（CRITICAL / HIGH）
            resource_id: 影響リソースの ID
            triage_result: Bedrock トリアージ結果（verdict, reason, action, risk_score）

        Returns:
            bool: 送信成功なら True、失敗なら False
        """
        try:
            token = self._get_token()
            message = self._build_message(
                title=title,
                severity=severity,
                resource_id=resource_id,
                triage_result=triage_result,
            )
            self._post_message(token=token, message=message)
            logger.info("Chatwork 通知送信成功: title=%s", title)
            return True

        except Exception as e:
            # 通知失敗はトリアージ処理全体を止めない
            logger.error("Chatwork 通知の送信に失敗しました: %s", e, exc_info=True)
            return False

    def _build_message(
        self,
        title: str,
        severity: str,
        resource_id: str,
        triage_result: dict,
    ) -> str:
        """
        Chatwork 通知メッセージを組み立てる。

        Args:
            title: Finding のタイトル
            severity: 重大度ラベル
            resource_id: 影響リソースの ID
            triage_result: トリアージ結果

        Returns:
            str: 送信するメッセージ文字列
        """
        verdict = triage_result.get("verdict", "監視継続")
        risk_score = triage_result.get("risk_score", 5)
        reason = triage_result.get("reason", "")
        action = triage_result.get("action", "")
        detected_at = datetime.now(JST).strftime("%Y-%m-%d %H:%M:%S JST")

        return (
            f"[info][title]🚨 Security Hub アラート - {verdict}[/title]\n"
            f"■ 検出名: {title}\n"
            f"■ 重大度: {severity}\n"
            f"■ リソース: {resource_id}\n"
            f"■ AI判定: {verdict}（リスクスコア: {risk_score}/10）\n"
            f"■ 理由: {reason}\n"
            f"■ 推奨アクション: {action}\n"
            f"■ 検出時刻: {detected_at}\n"
            f"[/info]"
        )

    def _post_message(self, token: str, message: str) -> None:
        """
        Chatwork API にメッセージを POST する。

        Args:
            token: Chatwork API トークン
            message: 送信するメッセージ

        Raises:
            urllib.error.HTTPError: API 呼び出しに失敗した場合
        """
        url = f"{CHATWORK_API_BASE}/rooms/{self._room_id}/messages"
        data = urllib.parse.urlencode({"body": message}).encode("utf-8")
        headers = {
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        }

        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(req) as response:
            logger.debug("Chatwork API レスポンス: status=%d", response.status)
