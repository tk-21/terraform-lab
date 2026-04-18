"""
BedrockClient モジュール

Amazon Bedrock (Claude Sonnet) を呼び出してIAM最小権限ポリシーを生成する。
ThrottlingException に対して指数バックオフでリトライする。
"""

import json
import logging
import re
import time

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = """\
あなたはAWS IAMセキュリティの専門家です。
現行のIAMポリシーと未使用アクションのリストを受け取り、最小権限の原則に従って
ポリシーを修正してください。

以下のJSONフォーマットのみで回答してください。説明文やMarkdownは不要です。

{
  "revised_policy": { /* 修正後のIAMポリシードキュメント（JSON）*/ },
  "removed_actions": ["削除したアクション一覧"],
  "reason": "変更理由の説明（日本語3〜5文）",
  "warnings": ["注意事項があれば記載（なければ空配列）"]
}

修正ルール:
1. unused_actions に含まれるアクションのみを削除する
2. Statement の構造・Condition・Resource 指定は変更しない
3. Effect: Allow の Statement のみ対象とする（Deny は変更しない）
4. 削除後にポリシーが空になる場合は removed_actions に全アクションを列挙し、\
warnings に「ポリシーが空になります。削除を検討してください」を追加する\
"""

_RETRY_DELAYS = [1, 2, 4]
_MARKDOWN_CODE_BLOCK_RE = re.compile(r"```(?:json)?\s*([\s\S]*?)\s*```")


class BedrockClient:
    """Amazon Bedrock を呼び出してポリシー最小権限化の提案を生成するクライアント。"""

    def __init__(self, model_id: str, client=None):
        """
        初期化。

        Args:
            model_id: 使用する Bedrock モデル ID
                      （例: anthropic.claude-sonnet-4-5）
            client: boto3 bedrock-runtime クライアント（省略時は自動生成）
        """
        self._model_id = model_id
        self._client = client or boto3.client("bedrock-runtime")

    def generate_least_privilege_policy(
        self,
        role_arn: str,
        current_policy: dict,
        unused_actions: list[str],
        last_accessed: str | None,
    ) -> dict | None:
        """
        現行ポリシーと未使用アクションを元に最小権限ポリシーの提案を生成して返す。

        IAM アクション: bedrock:InvokeModel

        ThrottlingException に対して指数バックオフ（1秒→2秒→4秒、最大3回）でリトライする。
        JSON パース失敗時・最大リトライ超過時は None を返す。

        Args:
            role_arn: 対象 IAM ロールの ARN
            current_policy: 現行のポリシードキュメント（dict）
            unused_actions: 未使用アクションの一覧
            last_accessed: 最終アクセス日時の文字列（ISO 8601）

        Returns:
            {"revised_policy": dict, "removed_actions": list, "reason": str, "warnings": list}
            失敗時は None
        """
        user_prompt = self._build_user_prompt(
            role_arn, current_policy, unused_actions, last_accessed
        )

        for attempt, delay in enumerate([0] + _RETRY_DELAYS, start=1):
            if delay:
                logger.info("Bedrock リトライ待機: %d 秒（試行 %d）", delay, attempt)
                time.sleep(delay)

            try:
                # IAM アクション: bedrock:InvokeModel
                raw_text = self._invoke_model(user_prompt)
                return self._parse_response(raw_text)

            except ClientError as e:
                code = e.response["Error"]["Code"]
                if code == "ThrottlingException" and attempt <= len(_RETRY_DELAYS):
                    logger.warning(
                        "ThrottlingException（試行 %d/%d）: %s",
                        attempt,
                        len(_RETRY_DELAYS) + 1,
                        e,
                    )
                    continue
                logger.error("Bedrock 呼び出し失敗: %s", e)
                return None

        logger.error("Bedrock 呼び出し失敗: 最大リトライ回数に達しました")
        return None

    # ------------------------------------------------------------------
    # 内部メソッド
    # ------------------------------------------------------------------

    def _build_user_prompt(
        self,
        role_arn: str,
        current_policy: dict,
        unused_actions: list[str],
        last_accessed: str | None,
    ) -> str:
        """
        Bedrock に送信するユーザープロンプトを組み立てて返す。

        Args:
            role_arn: 対象ロールの ARN
            current_policy: 現行ポリシードキュメント
            unused_actions: 未使用アクションの一覧
            last_accessed: 最終アクセス日時

        Returns:
            ユーザープロンプト文字列
        """
        return (
            f"## 対象ロール ARN\n{role_arn}\n\n"
            f"## 現行ポリシー（JSON）\n"
            f"{json.dumps(current_policy, ensure_ascii=False, indent=2)}\n\n"
            f"## 未使用アクション一覧\n"
            f"{json.dumps(unused_actions, ensure_ascii=False)}\n\n"
            f"## 最終アクセス日\n{last_accessed or '不明'}\n"
        )

    def _invoke_model(self, user_prompt: str) -> str:
        """
        Bedrock Messages API を呼び出してレスポンステキストを返す。

        IAM アクション: bedrock:InvokeModel

        Args:
            user_prompt: ユーザープロンプト文字列

        Returns:
            モデルが生成したテキスト

        Raises:
            ClientError: Bedrock API エラー
        """
        request_body = json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 4096,
                "system": _SYSTEM_PROMPT,
                "messages": [{"role": "user", "content": user_prompt}],
            }
        )

        # IAM アクション: bedrock:InvokeModel
        response = self._client.invoke_model(
            modelId=self._model_id,
            contentType="application/json",
            accept="application/json",
            body=request_body,
        )

        response_body = json.loads(response["body"].read())
        return response_body["content"][0]["text"]

    def _parse_response(self, raw_text: str) -> dict | None:
        """
        Bedrock のレスポンステキストをパースして辞書を返す。

        Markdown コードブロック（```json ... ``` または ``` ... ```）を除去してから
        json.loads() でパースする。パース失敗時は None を返す。

        Args:
            raw_text: Bedrock が返した生テキスト

        Returns:
            パース済み辞書。失敗時は None。
        """
        # AI出力検証: Markdown コードブロックを除去
        match = _MARKDOWN_CODE_BLOCK_RE.search(raw_text)
        json_text = match.group(1) if match else raw_text.strip()

        try:
            parsed = json.loads(json_text)
        except json.JSONDecodeError as e:
            logger.error(
                "Bedrock レスポンスの JSON パース失敗: %s\n--- raw ---\n%s",
                e,
                raw_text[:500],
            )
            return None

        required_keys = {"revised_policy", "removed_actions", "reason", "warnings"}
        missing = required_keys - parsed.keys()
        if missing:
            logger.error("Bedrock レスポンスに必須キーが不足: %s", missing)
            return None

        return parsed
