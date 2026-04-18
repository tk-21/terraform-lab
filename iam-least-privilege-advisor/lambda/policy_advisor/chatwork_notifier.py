"""
ChatworkNotifier モジュール

Secrets Manager から Chatwork API トークンを取得し、PR 作成完了を Chatwork に通知する。
通知失敗時は例外を送出せずエラーログのみ出力する（処理の継続を妨げない）。
"""

import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

JST = timezone(timedelta(hours=9))
CHATWORK_API_BASE = "https://api.chatwork.com/v2"


class ChatworkNotifier:
    """Chatwork API 経由でメッセージを送信するクライアント。"""

    def __init__(self, secret_arn: str, room_id: str, secrets_client=None):
        """
        初期化。

        Args:
            secret_arn: Chatwork Token を格納した Secrets Manager シークレットの ARN
            room_id: 通知先 Chatwork ルーム ID
            secrets_client: boto3 secretsmanager クライアント（省略時は自動生成）
        """
        self._secret_arn = secret_arn
        self._room_id = room_id
        self._secrets_client = secrets_client or boto3.client("secretsmanager")

    def notify_pr_created(
        self,
        role_name: str,
        removed_count: int,
        pr_url: str,
        scan_date: str,
    ) -> None:
        """
        PR 作成完了を CLAUDE.md 仕様のフォーマットで Chatwork に通知する。

        失敗時は例外を送出せずエラーログのみ出力する。

        Args:
            role_name: 対象 IAM ロール名
            removed_count: 削除されたアクション数
            pr_url: 作成した GitHub PR の URL
            scan_date: Access Analyzer スキャン日時（ISO 8601）
        """
        try:
            api_token = self._get_api_token()
            message = self._build_message(role_name, removed_count, pr_url, scan_date)
            self._post_message(api_token, message)
            logger.info("Chatwork 通知送信完了: room_id=%s", self._room_id)

        except ClientError as e:
            logger.error(
                "Chatwork 通知失敗（Secrets Manager エラー）: %s",
                e.response["Error"]["Code"],
            )
        except urllib.error.URLError as e:
            logger.error("Chatwork 通知失敗（HTTP エラー）: %s", e)
        except Exception as e:  # noqa: BLE001
            logger.error("Chatwork 通知失敗（予期しないエラー）: %s", e)

    # ------------------------------------------------------------------
    # 内部メソッド
    # ------------------------------------------------------------------

    def _get_api_token(self) -> str:
        """
        Secrets Manager から Chatwork API トークンを取得して返す。

        IAM アクション: secretsmanager:GetSecretValue

        シークレット形式: {"api_token": "<token>"}

        Returns:
            Chatwork API トークン文字列

        Raises:
            ClientError: Secrets Manager API エラー
            KeyError: シークレット内に "api_token" キーが存在しない場合
        """
        # IAM アクション: secretsmanager:GetSecretValue
        response = self._secrets_client.get_secret_value(SecretId=self._secret_arn)
        secret = json.loads(response["SecretString"])
        return secret["api_token"]

    def _build_message(
        self,
        role_name: str,
        removed_count: int,
        pr_url: str,
        scan_date: str,
    ) -> str:
        """
        CLAUDE.md 仕様の Chatwork 通知メッセージを組み立てて返す。

        Args:
            role_name: 対象 IAM ロール名
            removed_count: 削除されたアクション数
            pr_url: GitHub PR の URL
            scan_date: Access Analyzer スキャン日時文字列

        Returns:
            Chatwork 通知用メッセージ文字列
        """
        now_jst = datetime.now(JST).strftime("%Y-%m-%d %H:%M:%S JST")

        return (
            "[info][title]🔐 IAM 最小権限 PR 作成完了[/title]\n"
            f"■ 対象ロール: {role_name}\n"
            f"■ 削除アクション数: {removed_count}件\n"
            f"■ PR リンク: {pr_url}\n"
            f"■ 生成日時: {now_jst}\n"
            "⚠️ マージ前に必ずレビューしてください\n"
            "[/info]"
        )

    def _post_message(self, api_token: str, message: str) -> None:
        """
        Chatwork API にメッセージを POST する。

        Args:
            api_token: Chatwork API トークン
            message: 送信するメッセージ本文

        Raises:
            urllib.error.URLError: HTTP リクエスト失敗時
        """
        url = f"{CHATWORK_API_BASE}/rooms/{self._room_id}/messages"
        data = urllib.parse.urlencode({"body": message}).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"X-ChatWorkToken": api_token},
            method="POST",
        )

        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.status
            if status not in (200, 201):
                logger.warning("Chatwork API 予期しないステータス: %d", status)
            else:
                logger.debug("Chatwork API レスポンス: %d", status)
